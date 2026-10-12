CREATE OR REPLACE FUNCTION public.add_staff_bonus(_staff_id uuid, _amount numeric, _reason text, _bonus_date date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid := public.current_company_id(); v_id uuid;
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'invalid amount'; END IF;
  IF length(trim(coalesce(_reason,''))) < 3 THEN RAISE EXCEPTION 'reason required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id=_staff_id AND company_id=v_company) THEN RAISE EXCEPTION 'employee not found'; END IF;
  INSERT INTO public.staff_bonuses(company_id, staff_id, amount, reason, bonus_date, created_by)
  VALUES (v_company, _staff_id, round(_amount,2), trim(_reason), COALESCE(_bonus_date, CURRENT_DATE), public.current_profile_id())
  RETURNING id INTO v_id;
  PERFORM public.log_audit('payroll.bonus', 'payroll', 'staff_bonuses', v_id, NULL, jsonb_build_object('staff_id',_staff_id,'amount',_amount));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.set_employee_hire_date(_user_id uuid, _hire_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _hire_date IS NOT NULL AND _hire_date > CURRENT_DATE + 365 THEN RAISE EXCEPTION 'invalid hire date'; END IF;
  UPDATE public.user_profiles SET hire_date = _hire_date WHERE id = _user_id AND company_id = public.current_company_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'employee not found'; END IF;
  PERFORM public.log_audit('payroll.hire_date', 'payroll', 'user_profiles', _user_id, NULL, jsonb_build_object('hire_date',_hire_date));
END $$;