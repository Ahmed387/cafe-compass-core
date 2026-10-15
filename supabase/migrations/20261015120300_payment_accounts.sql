-- =====================================================================
-- Electronic payments: where the money lands, and what the cashier tells
-- the customer (client request: "تسوية الفيزا والمحافظ").
--
--  * InstaPay gets its own treasury account (it was merged into the wallet),
--    so InstaPay and Vodafone-cash balances can be reconciled separately.
--  * Each payment method stores the receiving handle / number (InstaPay
--    handle like name@instapay, wallet phone number) shown on the POS.
--  * Methods can be switched on/off from Settings (e.g. Visa until the
--    card machine arrives) — set_payment_method().
-- =====================================================================

ALTER TABLE public.payment_methods ADD COLUMN IF NOT EXISTS receiver_account text;

INSERT INTO public.cash_accounts (company_id, key, name, name_ar, account_type)
SELECT c.id, 'instapay', 'InstaPay', 'إنستاباي', 'wallet' FROM public.companies c
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.default_cash_account(_company_id uuid, _method text DEFAULT 'cash')
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(
    (SELECT id FROM public.cash_accounts
      WHERE company_id = _company_id AND is_active
        AND key = CASE
          WHEN lower(COALESCE(_method, 'cash')) IN ('card', 'visa', 'bank', 'transfer', 'bank_transfer') THEN 'bank'
          WHEN lower(COALESCE(_method, 'cash')) = 'instapay' THEN 'instapay'
          WHEN lower(COALESCE(_method, 'cash')) IN ('wallet', 'vodafone_cash', 'e_wallet') THEN 'wallet'
          ELSE 'main_cash' END
      LIMIT 1),
    -- Older companies without a dedicated InstaPay account keep using the wallet.
    CASE WHEN lower(COALESCE(_method, 'cash')) = 'instapay' THEN
      (SELECT id FROM public.cash_accounts WHERE company_id = _company_id AND is_active AND key = 'wallet' LIMIT 1) END)
$$;
REVOKE EXECUTE ON FUNCTION public.default_cash_account(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_payment_method(_method_id uuid, _is_active boolean, _receiver_account text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_old public.payment_methods;
BEGIN
  IF NOT (public.has_permission('settings.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO v_old FROM public.payment_methods WHERE id = _method_id AND company_id = public.current_company_id() FOR UPDATE;
  IF v_old.id IS NULL THEN RAISE EXCEPTION 'Payment method not found'; END IF;
  IF v_old.key = 'cash' AND NOT _is_active THEN RAISE EXCEPTION 'الكاش لازم يفضل شغال'; END IF;
  IF length(COALESCE(_receiver_account, '')) > 120 THEN RAISE EXCEPTION 'Value too long'; END IF;
  UPDATE public.payment_methods
     SET is_active = _is_active, receiver_account = NULLIF(btrim(COALESCE(_receiver_account, '')), ''), updated_at = now()
   WHERE id = _method_id;
  PERFORM public.log_audit('settings.payment_method', 'settings', 'payment_methods', _method_id,
    jsonb_build_object('is_active', v_old.is_active, 'receiver_account', v_old.receiver_account),
    jsonb_build_object('is_active', _is_active, 'receiver_account', _receiver_account), NULL, NULL);
END $$;
REVOKE ALL ON FUNCTION public.set_payment_method(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_payment_method(uuid, boolean, text) TO authenticated;
