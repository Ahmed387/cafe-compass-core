-- =====================================================================
-- Owner rules (2026-10-24), salaries and profit:
--   (a) The super admin can pick, by hand, which month a salary line counts
--       in for profit (pnl_month), whatever day it was paid. Empty = its own
--       payroll period, as before. Months already paid out are locked.
--   (b) A profit payout is blocked while an employee with a salary has no
--       salary line for a month in the payout range; the wizard lists them
--       with an estimate, so partners are never paid profit that still owes
--       salaries.
-- No existing data is changed.
-- =====================================================================

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

ALTER TABLE public.salary_payments ADD COLUMN IF NOT EXISTS pnl_month date;
DO $$ BEGIN
  ALTER TABLE public.salary_payments ADD CONSTRAINT salary_payments_pnl_month_first_day
    CHECK (pnl_month IS NULL OR extract(day FROM pnl_month) = 1);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN public.salary_payments.pnl_month IS
  'First day of the month this salary counts in for profit; NULL = its own period.';

-- The days a salary line's cost is spread over.
CREATE OR REPLACE FUNCTION public.salary_cost_from(_s public.salary_payments)
RETURNS date LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT COALESCE(_s.pnl_month, _s.period_start)
$$;
CREATE OR REPLACE FUNCTION public.salary_cost_to(_s public.salary_payments)
RETURNS date LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT CASE WHEN _s.pnl_month IS NULL THEN _s.period_end
              ELSE (_s.pnl_month + interval '1 month' - interval '1 day')::date END
$$;

-- Salary rows as the P&L sees them: period_start / period_end replaced by the cost days.
CREATE OR REPLACE FUNCTION public._salary_pnl_rows(_company uuid)
RETURNS SETOF public.salary_payments LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT (jsonb_populate_record(s, jsonb_build_object(
           'period_start', public.salary_cost_from(s), 'period_end', public.salary_cost_to(s)))).*
    FROM public.salary_payments s
   WHERE s.company_id = _company
$$;
REVOKE EXECUTE ON FUNCTION public._salary_pnl_rows(uuid) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.patch_fn('public._range_pnl(uuid, date, date)'::regprocedure,
$o$FROM public.salary_payments s$o$,
$n$FROM public._salary_pnl_rows(_company) s$n$);

-- ---------------------------------------------------------------------
-- (a) Pick the profit month of one salary line, with its effect first.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._month_paid_out(_company uuid, _from date, _to date)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM public.profit_distributions d
                  WHERE d.company_id = _company AND d.status = 'active' AND d.range_from IS NOT NULL
                    AND d.range_from <= _to AND d.range_to >= _from)
$$;
REVOKE EXECUTE ON FUNCTION public._month_paid_out(uuid, date, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.salary_pnl_month_preview(_salary_id uuid, _month date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _co uuid := public.current_company_id(); _s public.salary_payments; _new public.salary_payments;
  _cost numeric; _of date; _ot date; _nf date; _nt date; _blocker text;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _s FROM public.salary_payments WHERE id = _salary_id AND company_id = _co;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Salary record not found'; END IF;

  _new := _s;
  _new.pnl_month := CASE WHEN _month IS NULL OR date_trunc('month', _month)::date = date_trunc('month', _s.period_start)::date
                              AND _s.period_start = date_trunc('month', _s.period_start)::date
                              AND _s.period_end = (date_trunc('month', _s.period_start) + interval '1 month' - interval '1 day')::date
                         THEN NULL ELSE date_trunc('month', _month)::date END;
  _cost := public.salary_line_cost(_s);
  _of := public.salary_cost_from(_s); _ot := public.salary_cost_to(_s);
  _nf := public.salary_cost_from(_new); _nt := public.salary_cost_to(_new);

  IF _s.status <> 'active' THEN _blocker := 'سطر المرتب ده مش نشط';
  ELSIF public._month_paid_out(_co, _of, _ot) THEN _blocker := 'أرباح الشهر اللي المرتب محسوب عليه اتوزعت خلاص';
  ELSIF public._month_paid_out(_co, _nf, _nt) THEN _blocker := 'أرباح الشهر اللي اخترته اتوزعت خلاص';
  END IF;

  RETURN jsonb_build_object(
    'salary_id', _s.id, 'cost', round(_cost, 2), 'net_amount', _s.net_amount,
    'period_start', _s.period_start, 'period_end', _s.period_end, 'paid_at', _s.paid_at,
    'current_from', _of, 'current_to', _ot, 'new_from', _nf, 'new_to', _nt,
    'pnl_month', _new.pnl_month, 'changed', (_of, _ot) IS DISTINCT FROM (_nf, _nt),
    'current_month_net', (public._range_pnl(_co, _of, _ot)->>'net_profit')::numeric,
    'new_month_net', (public._range_pnl(_co, _nf, _nt)->>'net_profit')::numeric,
    'can_change', _blocker IS NULL, 'blocker', _blocker);
END $$;

CREATE OR REPLACE FUNCTION public.set_salary_pnl_month(_salary_id uuid, _month date, _note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _pv jsonb; _s public.salary_payments;
BEGIN
  _pv := public.salary_pnl_month_preview(_salary_id, _month);
  IF NOT (_pv->>'changed')::boolean THEN RETURN _pv || jsonb_build_object('saved', false); END IF;
  IF NOT (_pv->>'can_change')::boolean THEN RAISE EXCEPTION '%', _pv->>'blocker'; END IF;
  SELECT * INTO _s FROM public.salary_payments WHERE id = _salary_id FOR UPDATE;
  UPDATE public.salary_payments SET pnl_month = (_pv->>'pnl_month')::date, updated_at = now() WHERE id = _salary_id;
  PERFORM public.log_audit('payroll.pnl_month', 'payroll', 'salary_payments', _salary_id,
    jsonb_build_object('pnl_month', _s.pnl_month, 'from', _pv->'current_from', 'to', _pv->'current_to'),
    jsonb_build_object('pnl_month', _pv->'pnl_month', 'from', _pv->'new_from', 'to', _pv->'new_to', 'cost', _pv->'cost'),
    NULLIF(btrim(COALESCE(_note, '')), ''), NULL);
  RETURN _pv || jsonb_build_object('saved', true);
END $$;

REVOKE ALL ON FUNCTION public.salary_pnl_month_preview(uuid, date), public.set_salary_pnl_month(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.salary_pnl_month_preview(uuid, date), public.set_salary_pnl_month(uuid, date, text) TO authenticated;

-- ---------------------------------------------------------------------
-- (b) Salaries still missing for a payout range.
--     Every month the range touches: employees with a salary and no salary
--     line. Estimate = their payroll net + advances (the P&L cost), for the
--     days of the month inside the range.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._payroll_missing(_company uuid, _from date, _to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _m date; _me date; _lines jsonb := '[]'::jsonb; _total numeric := 0; _r record; _est numeric; _days numeric; _mdays numeric;
BEGIN
  _m := date_trunc('month', _from)::date;
  WHILE _m <= _to LOOP
    _me := (_m + interval '1 month' - interval '1 day')::date;
    _mdays := _me - _m + 1;
    _days := LEAST(_me, _to) - GREATEST(_m, _from) + 1;
    FOR _r IN SELECT * FROM public._payroll_lines(_company, _m, _me) x
               WHERE NOT x.already_generated AND x.prorated_salary > 0 LOOP
      _est := round((_r.net_pay + _r.advances) * _days / _mdays, 2);
      _lines := _lines || jsonb_build_array(jsonb_build_object(
        'user_id', _r.user_id, 'name', _r.employee_name, 'month', _m, 'estimate', _est));
      _total := _total + _est;
    END LOOP;
    _m := (_m + interval '1 month')::date;
  END LOOP;
  RETURN jsonb_build_object('lines', _lines, 'total', round(_total, 2), 'count', jsonb_array_length(_lines));
END $$;
REVOKE EXECUTE ON FUNCTION public._payroll_missing(uuid, date, date) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.patch_fn('public._payout_calc(uuid, date, date, numeric)'::regprocedure,
$o$'shares_total_100', _shares_ok)$o$,
$n$'shares_total_100', _shares_ok,
      'payroll_recorded', (public._payroll_missing(_company, _from, _to)->>'count')::int = 0),
    'payroll_missing', public._payroll_missing(_company, _from, _to)$n$);
