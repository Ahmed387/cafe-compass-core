CREATE OR REPLACE FUNCTION public.update_shift_closing_cash(_shift_id uuid, _closing_cash numeric, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _variance numeric;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('shifts.close')) THEN
    RAISE EXCEPTION 'غير مصرح بتعديل النقدية الختامية';
  END IF;
  IF _closing_cash IS NULL OR _closing_cash < 0 THEN RAISE EXCEPTION 'قيمة غير صالحة'; END IF;
  IF coalesce(length(trim(_reason)),0) < 3 THEN RAISE EXCEPTION 'يجب كتابة سبب التعديل'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id AND company_id = public.current_company_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الوردية غير موجودة'; END IF;
  IF _s.status <> 'closed' THEN RAISE EXCEPTION 'الوردية لم تُغلق بعد'; END IF;
  PERFORM public.assert_period_open(_s.company_id, (_s.closed_at)::date);
  _variance := _closing_cash - coalesce(_s.expected_cash, 0);
  UPDATE public.shifts SET closing_cash = _closing_cash, variance = _variance, updated_at = now() WHERE id = _shift_id;
  PERFORM public.log_audit('update_closing_cash','shifts','shift',_shift_id,
    jsonb_build_object('closing_cash',_s.closing_cash,'variance',_s.variance),
    jsonb_build_object('closing_cash',_closing_cash,'variance',_variance), _reason, _s.branch_id);
  RETURN jsonb_build_object('closing_cash',_closing_cash,'variance',_variance);
END $$;
REVOKE ALL ON FUNCTION public.update_shift_closing_cash(uuid,numeric,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_shift_closing_cash(uuid,numeric,text) TO authenticated;