-- =====================================================================
-- live_position(): one call for "where do we stand right now".
--   drawers  → every open shift: opening float + cash sales − cash refunds −
--              drawer expenses = cash that should be in the drawer now,
--              plus what came in by InstaPay / wallet / card / partner tab
--   accounts → balance of every treasury account (main safe, bank, wallet, InstaPay)
--   today / month → revenue, cost of goods, gross profit, expenses, payroll, net
--              (same engine as the P&L page). The month also deducts salaries not
--              issued yet, for the days already worked, so the figure is net
--              before payday too (salary is monthly; the share to date is
--              monthly × days passed ÷ days in month).
-- Profit figures only for users who may see profit; drawers for shift viewers.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.live_position()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _company uuid := public.current_company_id();
  _today date; _m0 date; _m1 date; _days int; _passed int;
  _can_profit boolean; _can_cash boolean;
  _drawers jsonb; _accounts jsonb; _pnl_today jsonb; _pnl_month jsonb;
  _salary_month numeric := 0; _salary_accrued numeric := 0;
BEGIN
  IF public.current_profile_id() IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  _can_profit := public.is_super_admin() OR public.has_permission('reports.profit') OR public.has_permission('partners.view_profit');
  _can_cash := _can_profit OR public.has_permission('shifts.view') OR public.has_permission('expenses.view');
  IF NOT _can_cash THEN RAISE EXCEPTION 'Not authorized'; END IF;

  _today := public.business_today(_company);
  _m0 := date_trunc('month', _today)::date;
  _m1 := (date_trunc('month', _today) + interval '1 month - 1 day')::date;
  _days := _m1 - _m0 + 1;
  _passed := _today - _m0 + 1;

  SELECT COALESCE(jsonb_agg(d ORDER BY d->>'opened_at'), '[]'::jsonb) INTO _drawers
  FROM (
    SELECT jsonb_build_object(
      'shift_id', s.id, 'branch_id', s.branch_id,
      'cashier', COALESCE(NULLIF(up.display_name, ''), up.first_name),
      'opened_at', s.opened_at, 'opening_cash', s.opening_cash,
      'cash_in', x.cash_in, 'cash_refunds', x.cash_out, 'drawer_expenses', x.exp,
      'drawer_now', round(s.opening_cash + x.cash_in - x.cash_out - x.exp, 2),
      'orders', x.orders, 'tenders', x.tenders) AS d
    FROM public.shifts s
    LEFT JOIN public.user_profiles up ON up.id = s.user_id
    CROSS JOIN LATERAL (
      SELECT
        (SELECT COALESCE(SUM(p.amount), 0) FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
          WHERE o.shift_id = s.id AND p.method_key = 'cash') AS cash_in,
        (SELECT COALESCE(SUM(r.amount), 0) FROM public.order_refunds r
          WHERE r.shift_id = s.id AND r.status = 'active' AND COALESCE(r.method_key, 'cash') = 'cash') AS cash_out,
        public.shift_expense_total(s.id) AS exp,
        (SELECT count(*) FROM public.orders o WHERE o.shift_id = s.id AND o.status <> 'cancelled') AS orders,
        (SELECT COALESCE(jsonb_object_agg(k, v), '{}'::jsonb) FROM (
           SELECT public.tender_key(p.method_key) k, round(SUM(p.amount), 2) v
             FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
            WHERE o.shift_id = s.id GROUP BY 1) t) AS tenders
    ) x
    WHERE s.company_id = _company AND s.status = 'open' AND public.can_access_branch(s.branch_id)
  ) q;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('key', ca.key, 'name', COALESCE(ca.name_ar, ca.name),
           'balance', round(ca.opening_balance + COALESCE(b.net, 0), 2)) ORDER BY ca.is_default DESC, ca.key), '[]'::jsonb)
    INTO _accounts
    FROM public.cash_accounts ca
    LEFT JOIN LATERAL (
      SELECT SUM(CASE WHEN ct.direction = 'in' THEN ct.amount ELSE -ct.amount END) net
        FROM public.cash_transactions ct WHERE ct.account_id = ca.id AND ct.status = 'active') b ON true
   WHERE ca.company_id = _company AND ca.is_active;

  IF _can_profit THEN
    _pnl_today := public._range_pnl(_company, _today, _today);
    _pnl_month := public._range_pnl(_company, _m0, _today);
    SELECT COALESCE(SUM(l.prorated_salary), 0),
           COALESCE(SUM(l.prorated_salary) FILTER (WHERE NOT l.already_generated), 0) * _passed / _days
      INTO _salary_month, _salary_accrued
      FROM public._payroll_lines(_company, _m0, _m1) l;
    _salary_accrued := round(_salary_accrued, 2);
  END IF;

  RETURN jsonb_build_object(
    'as_of', now(), 'business_day', _today, 'month_start', _m0, 'days_passed', _passed, 'days_in_month', _days,
    'drawers', _drawers, 'accounts', _accounts,
    'cash_total', (SELECT COALESCE(SUM((a->>'balance')::numeric), 0) FROM jsonb_array_elements(_accounts) a)
                  + (SELECT COALESCE(SUM((d->>'drawer_now')::numeric), 0) FROM jsonb_array_elements(_drawers) d),
    'can_profit', _can_profit,
    'today', CASE WHEN _can_profit THEN jsonb_build_object(
        'orders', _pnl_today->'orders_count', 'revenue', _pnl_today->'revenue', 'cogs', _pnl_today->'cogs',
        'gross_profit', _pnl_today->'gross_profit', 'expenses', _pnl_today->'expenses_total',
        'net_before_salaries', round((_pnl_today->>'gross_profit')::numeric - (_pnl_today->>'expenses_total')::numeric, 2)) END,
    'month', CASE WHEN _can_profit THEN jsonb_build_object(
        'orders', _pnl_month->'orders_count', 'revenue', _pnl_month->'revenue', 'cogs', _pnl_month->'cogs',
        'gross_profit', _pnl_month->'gross_profit', 'expenses', _pnl_month->'expenses_total',
        'payroll_recorded', _pnl_month->'payroll_total', 'salaries_accrued', _salary_accrued,
        'salaries_full_month', round(_salary_month, 2),
        'other_losses', round((_pnl_month->>'cash_shortage')::numeric - (_pnl_month->>'cash_over')::numeric, 2),
        'net_profit', round((_pnl_month->>'net_profit')::numeric - _salary_accrued, 2)) END);
END $$;
REVOKE ALL ON FUNCTION public.live_position() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.live_position() TO authenticated, service_role;
