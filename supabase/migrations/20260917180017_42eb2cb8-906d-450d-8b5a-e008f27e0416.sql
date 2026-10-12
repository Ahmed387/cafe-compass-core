CREATE OR REPLACE FUNCTION public.correct_expense_amount(_expense_id uuid, _new_amount numeric, _reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _e public.expenses; _acc uuid; _delta numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the super admin can correct an expense amount'; END IF;
  IF _new_amount IS NULL OR _new_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 5 THEN RAISE EXCEPTION 'A correction reason is required'; END IF;

  SELECT * INTO _e FROM public.expenses
   WHERE id = _expense_id AND company_id = public.current_company_id();
  IF _e.id IS NULL THEN RAISE EXCEPTION 'Expense not found'; END IF;
  IF _e.status <> 'active' THEN RAISE EXCEPTION 'Only active expenses can be corrected'; END IF;
  PERFORM public.assert_period_open(_e.company_id, _e.expense_date);
  IF round(_e.amount, 2) = round(_new_amount, 2) THEN RAISE EXCEPTION 'The new amount matches the current amount'; END IF;

  _delta := round(_new_amount, 2) - round(_e.amount, 2);

  UPDATE public.expenses
     SET amount = round(_new_amount, 2), updated_at = now()
   WHERE id = _expense_id;

  IF _e.approved_at IS NOT NULL THEN
    _acc := public.default_cash_account(_e.company_id, COALESCE(NULLIF(_e.payment_method,''),'cash'));
    IF _acc IS NOT NULL AND _delta <> 0 THEN
      PERFORM public.post_cash_txn(_e.company_id, _acc,
        CASE WHEN _delta > 0 THEN 'out' ELSE 'in' END, abs(_delta), 'expense',
        COALESCE(NULLIF(_e.payment_method,''),'cash'), _e.expense_date, 'expense', _expense_id,
        'Expense correction: ' || btrim(_reason), NULL, false);
    END IF;
  END IF;

  PERFORM public.log_audit('expense.correct_amount','finance','expenses',_expense_id,
    jsonb_build_object('amount', _e.amount),
    jsonb_build_object('amount', round(_new_amount,2), 'delta', _delta),
    btrim(_reason), _e.branch_id);

  RETURN _expense_id;
END $function$;

REVOKE ALL ON FUNCTION public.correct_expense_amount(uuid, numeric, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.correct_expense_amount(uuid, numeric, text) TO authenticated, service_role;