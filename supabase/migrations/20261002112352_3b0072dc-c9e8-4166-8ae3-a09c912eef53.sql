CREATE OR REPLACE FUNCTION public.forbid_hard_delete()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('app.allow_test_reset', true) = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'Records in % are append-only and cannot be deleted', TG_TABLE_NAME;
END $$;

CREATE OR REPLACE FUNCTION public.reset_test_shift(_shift_id uuid, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s record; n_orders int;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Super Admin only'; END IF;
  IF coalesce(length(trim(_reason)),0) < 3 THEN RAISE EXCEPTION 'Reason required'; END IF;
  SELECT * INTO s FROM shifts WHERE id = _shift_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF s.status <> 'closed' THEN RAISE EXCEPTION 'Close the shift first'; END IF;
  IF EXISTS (SELECT 1 FROM partner_tab_orders p JOIN orders o ON o.id=p.order_id WHERE o.shift_id=_shift_id) THEN
    RAISE EXCEPTION 'Shift has partner tab orders and cannot be reset';
  END IF;
  SELECT count(*) INTO n_orders FROM orders WHERE shift_id=_shift_id;

  PERFORM set_config('app.allow_test_reset','on',true);
  PERFORM public.log_audit('reset_test_shift','shifts','shift',_shift_id, to_jsonb(s), jsonb_build_object('orders_removed',n_orders), _reason, s.branch_id);

  DELETE FROM customer_points_transactions WHERE order_id IN (SELECT id FROM orders WHERE shift_id=_shift_id);
  UPDATE customer_vouchers SET order_id=NULL WHERE order_id IN (SELECT id FROM orders WHERE shift_id=_shift_id);
  DELETE FROM staff_penalties WHERE shift_id=_shift_id;
  DELETE FROM order_refunds WHERE shift_id=_shift_id OR order_id IN (SELECT id FROM orders WHERE shift_id=_shift_id);
  DELETE FROM order_payments WHERE order_id IN (SELECT id FROM orders WHERE shift_id=_shift_id);
  DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE shift_id=_shift_id);
  DELETE FROM orders WHERE shift_id=_shift_id;
  UPDATE customer_vouchers SET expense_id=NULL WHERE expense_id IN (SELECT id FROM expenses WHERE shift_id=_shift_id);
  DELETE FROM expenses WHERE shift_id=_shift_id;
  UPDATE purchase_payments SET shift_id=NULL WHERE shift_id=_shift_id;
  UPDATE stocktakes SET settle_shift_id=NULL WHERE settle_shift_id=_shift_id;
  DELETE FROM shifts WHERE id=_shift_id;
  PERFORM set_config('app.allow_test_reset','off',true);
  RETURN jsonb_build_object('ok',true,'orders_removed',n_orders);
END $$;
REVOKE ALL ON FUNCTION public.reset_test_shift(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reset_test_shift(uuid,text) TO authenticated;