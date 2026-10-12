INSERT INTO public.permissions (key, name, module)
SELECT 'inventory.emergency_transfer', 'Emergency bar transfer', 'inventory'
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE key = 'inventory.emergency_transfer');

INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
CROSS JOIN public.permissions p
WHERE r.name IN ('Super Admin', 'Manager', 'Cashier')
  AND p.key = 'inventory.emergency_transfer'
  AND NOT EXISTS (
    SELECT 1 FROM public.role_permissions rp
    WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );

CREATE OR REPLACE FUNCTION public.set_role_permission(
  _role_id uuid,
  _permission_key text,
  _enabled boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _role public.roles;
  _permission_id uuid;
  _old boolean;
BEGIN
  IF NOT (public.has_permission('users.manage_roles') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _role
  FROM public.roles
  WHERE id = _role_id AND company_id = public.current_company_id()
  FOR UPDATE;
  IF _role.id IS NULL THEN RAISE EXCEPTION 'Role not found'; END IF;
  IF _role.name = 'Super Admin' AND NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the Root Super Admin can change Super Admin permissions';
  END IF;

  SELECT id INTO _permission_id FROM public.permissions WHERE key = _permission_key;
  IF _permission_id IS NULL THEN RAISE EXCEPTION 'Permission not found'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.role_permissions
    WHERE role_id = _role_id AND permission_id = _permission_id
  ) INTO _old;

  IF _enabled THEN
    INSERT INTO public.role_permissions(role_id, permission_id)
    VALUES (_role_id, _permission_id)
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.role_permissions
    WHERE role_id = _role_id AND permission_id = _permission_id;
  END IF;

  PERFORM public.log_audit(
    'role.permissions_change', 'users', 'roles', _role_id,
    jsonb_build_object('permission', _permission_key, 'enabled', _old),
    jsonb_build_object('permission', _permission_key, 'enabled', _enabled),
    NULL, NULL
  );
END
$function$;
REVOKE EXECUTE ON FUNCTION public.set_role_permission(uuid,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_role_permission(uuid,text,boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.emergency_stock_transfer(_branch_id uuid, _items jsonb, _notes text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _id uuid; _it jsonb; _n int := 0; _main numeric; _name text; _cost numeric;
  _q numeric; _item uuid; _company uuid := public.current_company_id();
  _me uuid := public.current_profile_id();
BEGIN
  IF NOT (public.has_permission('inventory.emergency_transfer') OR public.is_super_admin())
     OR NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  INSERT INTO public.stock_transfers(company_id, branch_id, notes, requested_by, status, decided_by, decided_at)
  VALUES (_company, _branch_id, COALESCE(NULLIF(trim(_notes),''),'تحويل طارئ من الكاشير'), _me, 'approved', _me, now())
  RETURNING id INTO _id;
  FOR _it IN SELECT * FROM jsonb_array_elements(COALESCE(_items,'[]')) LOOP
    _q := COALESCE((_it->>'quantity')::numeric,0);
    IF _q <= 0 THEN CONTINUE; END IF;
    SELECT i.id, i.name, i.cost_per_unit INTO _item, _name, _cost
    FROM public.inventory_items i
    WHERE i.id = (_it->>'item_id')::uuid AND i.company_id = _company;
    IF _item IS NULL THEN RAISE EXCEPTION 'Item not found'; END IF;
    SELECT bs.quantity - bs.bar_quantity INTO _main
    FROM public.branch_stock bs
    WHERE bs.item_id = _item AND bs.branch_id = _branch_id FOR UPDATE;
    IF COALESCE(_main,0) < _q THEN
      RAISE EXCEPTION 'المخزن الرئيسي لا يكفي: % (متاح %)', _name, COALESCE(_main,0);
    END IF;
    INSERT INTO public.stock_transfer_items(transfer_id, item_id, quantity) VALUES (_id, _item, _q);
    UPDATE public.branch_stock SET bar_quantity = bar_quantity + _q, updated_at = now()
    WHERE item_id = _item AND branch_id = _branch_id;
    INSERT INTO public.stock_movements(company_id, branch_id, item_id, movement_type, quantity, unit_cost, balance_after, reference_type, reference_id, reason, created_by, location)
    SELECT _company, _branch_id, _item, 'transfer_out', -_q, _cost, bs.quantity - bs.bar_quantity,
      'stock_transfer', _id, 'Main → Bar (طارئ)', _me, 'main'
    FROM public.branch_stock bs WHERE bs.item_id=_item AND bs.branch_id=_branch_id;
    INSERT INTO public.stock_movements(company_id, branch_id, item_id, movement_type, quantity, unit_cost, balance_after, reference_type, reference_id, reason, created_by, location)
    SELECT _company, _branch_id, _item, 'transfer_in', _q, _cost, bs.bar_quantity,
      'stock_transfer', _id, 'Main → Bar (طارئ)', _me, 'bar'
    FROM public.branch_stock bs WHERE bs.item_id=_item AND bs.branch_id=_branch_id;
    _n := _n + 1;
  END LOOP;
  IF _n = 0 THEN RAISE EXCEPTION 'أضف صنفًا واحدًا على الأقل'; END IF;
  PERFORM public.log_audit('stock_transfer.emergency','inventory','stock_transfer',_id,NULL,_items,_notes,_branch_id);
  RETURN _id;
END
$function$;
REVOKE EXECUTE ON FUNCTION public.emergency_stock_transfer(uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emergency_stock_transfer(uuid,jsonb,text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.period_financial_kpis(_period_id uuid)
RETURNS TABLE(
  gross_revenue numeric,
  yielded_cogs numeric,
  gross_margin numeric,
  opex_and_shrinkage numeric,
  net_operating_profit numeric,
  drawer_variance numeric,
  venue_shrinkage numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _p public.accounting_periods;
  _pnl record;
  _shrink numeric := 0;
  _variance numeric := 0;
  _ycogs numeric := 0;
  _margin numeric := 0;
  _opex numeric := 0;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods
  WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  SELECT * INTO _pnl FROM public.period_pnl(_period_id);
  SELECT COALESCE(SUM(st.shortage_cost),0) INTO _shrink
  FROM public.stocktakes st
  WHERE st.company_id = _p.company_id
    AND COALESCE(st.settlement,'venue') = 'venue'
    AND st.created_at::date BETWEEN _p.start_date AND _p.end_date;
  SELECT COALESCE(SUM(s.variance),0) INTO _variance
  FROM public.shifts s
  WHERE s.company_id = _p.company_id AND s.status = 'closed'
    AND s.opened_at::date BETWEEN _p.start_date AND _p.end_date;

  _ycogs := round(COALESCE(_pnl.cogs,0) * 1.05, 2);
  _margin := round(COALESCE(_pnl.revenue,0) - _ycogs, 2);
  _opex := round(COALESCE(_pnl.expenses_total,0) + COALESCE(_pnl.payroll_total,0) + COALESCE(_pnl.waste_cost,0), 2);

  RETURN QUERY SELECT
    round(COALESCE(_pnl.gross_sales,0),2),
    _ycogs,
    _margin,
    _opex,
    round(_margin - _opex,2),
    round(_variance,2),
    round(_shrink,2);
END
$function$;
REVOKE EXECUTE ON FUNCTION public.period_financial_kpis(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.period_financial_kpis(uuid) TO authenticated, service_role;

CREATE TABLE public.partner_liquidations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  partner_id uuid NOT NULL REFERENCES public.partners(id),
  final_balance numeric NOT NULL,
  settlement_method text NOT NULL CHECK (settlement_method IN ('treasury','bank','ledger')),
  cash_account_id uuid REFERENCES public.cash_accounts(id),
  cash_transaction_id uuid REFERENCES public.cash_transactions(id),
  redistribution jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes text,
  performed_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.partner_liquidations TO authenticated;
GRANT ALL ON public.partner_liquidations TO service_role;
ALTER TABLE public.partner_liquidations ENABLE ROW LEVEL SECURITY;
CREATE POLICY partner_liquidations_select ON public.partner_liquidations
FOR SELECT TO authenticated
USING (
  company_id = public.current_company_id()
  AND (public.has_permission('partners.view_profit') OR public.is_super_admin())
);

CREATE OR REPLACE FUNCTION public.liquidate_partner(
  _partner_id uuid,
  _settlement_method text,
  _cash_account_id uuid DEFAULT NULL,
  _notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _partner public.partners;
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _balance numeric;
  _cash_txn uuid;
  _liquidation uuid := gen_random_uuid();
  _total numeric := 0;
  _running numeric := 0;
  _count int := 0;
  _index int := 0;
  _share numeric;
  _redistribution jsonb := '{}'::jsonb;
  _row record;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can liquidate a partnership'; END IF;
  IF _settlement_method NOT IN ('treasury','bank','ledger') THEN RAISE EXCEPTION 'Invalid settlement method'; END IF;

  SELECT * INTO _partner FROM public.partners
  WHERE id = _partner_id AND company_id = _company FOR UPDATE;
  IF _partner.id IS NULL THEN RAISE EXCEPTION 'Partner not found'; END IF;
  IF _partner.status <> 'active' THEN RAISE EXCEPTION 'Partner is already inactive'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.partner_withdrawal_requests
    WHERE partner_id = _partner_id AND status = 'pending'
  ) THEN RAISE EXCEPTION 'Resolve pending withdrawal requests before liquidation'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.partner_tab_orders
    WHERE partner_id = _partner_id AND NOT is_settled
  ) THEN RAISE EXCEPTION 'Settle partner tabs before liquidation'; END IF;

  SELECT count(*), COALESCE(SUM(COALESCE(po.profit_share_percentage, ow.ownership_percentage,0)),0)
  INTO _count, _total
  FROM public.partners po
  LEFT JOIN public.partner_ownership ow ON ow.partner_id = po.id
  WHERE po.company_id = _company AND po.status = 'active' AND po.id <> _partner_id;
  IF _count = 0 OR _total <= 0 THEN RAISE EXCEPTION 'At least one active partner with equity must remain'; END IF;

  _balance := public.partner_balance(_partner_id);
  IF _balance > 0 AND _settlement_method = 'treasury' THEN
    IF _cash_account_id IS NULL THEN RAISE EXCEPTION 'Select a treasury account'; END IF;
    _cash_txn := public.post_cash_txn(
      _company, _cash_account_id, 'out', _balance, 'partner_liquidation', 'cash', CURRENT_DATE,
      'partner_liquidation', _liquidation, 'Partner liquidation: ' || _partner.name, NULL, true
    );
  END IF;

  IF _balance <> 0 THEN
    INSERT INTO public.partner_ledger_transactions(
      company_id, partner_id, transaction_type, amount, reference_type, reference_id,
      description, transaction_date, created_by
    ) VALUES (
      _company, _partner_id, 'withdrawal', abs(_balance), 'partner_liquidation', _liquidation,
      COALESCE(NULLIF(_notes,''),'Final partnership settlement (' || _settlement_method || ')'),
      CURRENT_DATE, _profile
    );
  END IF;

  FOR _row IN
    SELECT po.id, COALESCE(po.profit_share_percentage, ow.ownership_percentage,0) AS current_share
    FROM public.partners po
    LEFT JOIN public.partner_ownership ow ON ow.partner_id = po.id
    WHERE po.company_id = _company AND po.status = 'active' AND po.id <> _partner_id
    ORDER BY po.id
    FOR UPDATE OF po
  LOOP
    _index := _index + 1;
    IF _index = _count THEN
      _share := round(100 - _running, 4);
    ELSE
      _share := round((_row.current_share / _total) * 100, 4);
      _running := _running + _share;
    END IF;
    UPDATE public.partners SET profit_share_percentage = _share, updated_at = now() WHERE id = _row.id;
    _redistribution := _redistribution || jsonb_build_object(_row.id::text, _share);
  END LOOP;

  UPDATE public.partners
  SET status = 'inactive', profit_share_percentage = 0, updated_at = now()
  WHERE id = _partner_id;

  IF round((SELECT COALESCE(SUM(profit_share_percentage),0) FROM public.partners
            WHERE company_id = _company AND status = 'active'),4) <> 100 THEN
    RAISE EXCEPTION 'Active partner equity must total 100%%';
  END IF;

  INSERT INTO public.partner_liquidations(
    id, company_id, partner_id, final_balance, settlement_method, cash_account_id,
    cash_transaction_id, redistribution, notes, performed_by
  ) VALUES (
    _liquidation, _company, _partner_id, _balance, _settlement_method,
    CASE WHEN _settlement_method='treasury' THEN _cash_account_id ELSE NULL END,
    _cash_txn, _redistribution, NULLIF(_notes,''), _profile
  );

  PERFORM public.log_audit(
    'partner.liquidate','partners','partners',_partner_id,to_jsonb(_partner),
    jsonb_build_object('status','inactive','final_balance',_balance,'settlement_method',_settlement_method,'redistribution',_redistribution),
    _notes,NULL
  );
  RETURN _liquidation;
END
$function$;
REVOKE EXECUTE ON FUNCTION public.liquidate_partner(uuid,text,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.liquidate_partner(uuid,text,uuid,text) TO authenticated, service_role;