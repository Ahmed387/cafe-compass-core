-- ============ A) AUTOMATIC ACCOUNTING PERIODS ============
ALTER TABLE public.accounting_periods
  ADD COLUMN IF NOT EXISTS auto_created boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.ensure_open_periods()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE _c record; _created integer := 0; _start date; _end date;
BEGIN
  _start := date_trunc('month', CURRENT_DATE)::date;
  _end := (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date;
  FOR _c IN SELECT id FROM public.companies LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.accounting_periods ap
      WHERE ap.company_id = _c.id
        AND CURRENT_DATE BETWEEN ap.start_date AND ap.end_date
    ) THEN
      INSERT INTO public.accounting_periods (company_id, period_type, start_date, end_date, status, auto_created)
      VALUES (_c.id, 'monthly', _start, _end, 'open', true);
      _created := _created + 1;
    END IF;
  END LOOP;
  RETURN _created;
END $$;

CREATE OR REPLACE FUNCTION public.notify_periods_due()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE _p record; _n integer := 0;
BEGIN
  FOR _p IN
    SELECT ap.id, ap.company_id, ap.start_date, ap.end_date
    FROM public.accounting_periods ap
    WHERE ap.status = 'open' AND ap.end_date < CURRENT_DATE
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.company_id = _p.company_id
        AND n.type = 'period.due'
        AND n.data->>'period_id' = _p.id::text
        AND n.created_at > now() - interval '20 hours'
    ) THEN
      INSERT INTO public.notifications (company_id, type, severity, title, body, required_permission, data)
      VALUES (
        _p.company_id, 'period.due', 'warning',
        'فترة مالية محتاجة تقفيل',
        'الفترة من ' || _p.start_date || ' إلى ' || _p.end_date || ' خلصت ولسه مفتوحة. راجع الأرباح والخسائر واقفلها.',
        'periods.manage',
        jsonb_build_object('period_id', _p.id, 'start_date', _p.start_date, 'end_date', _p.end_date)
      );
      _n := _n + 1;
    END IF;
  END LOOP;
  RETURN _n;
END $$;

GRANT EXECUTE ON FUNCTION public.ensure_open_periods() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.notify_periods_due() TO authenticated, service_role;

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  PERFORM cron.unschedule('ensure-open-periods');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM cron.unschedule('notify-periods-due');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT cron.schedule('ensure-open-periods', '10 0 * * *', $$SELECT public.ensure_open_periods();$$);
SELECT cron.schedule('notify-periods-due', '0 6 * * *', $$SELECT public.notify_periods_due();$$);

SELECT public.ensure_open_periods();

-- ============ B) PURCHASE PAYMENTS / SUPPLIER BALANCE ============
ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS paid_amount numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS returned_amount numeric NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.purchase_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  purchase_id uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  amount numeric NOT NULL CHECK (amount > 0),
  method text,
  paid_at date NOT NULL DEFAULT CURRENT_DATE,
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.purchase_payments TO authenticated;
GRANT ALL ON public.purchase_payments TO service_role;
ALTER TABLE public.purchase_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "purchase_payments_view" ON public.purchase_payments;
CREATE POLICY "purchase_payments_view" ON public.purchase_payments
FOR SELECT TO authenticated
USING (company_id = public.current_company_id()
  AND (public.has_permission('purchases.view') OR public.has_permission('purchases.create') OR public.is_super_admin()));

CREATE INDEX IF NOT EXISTS purchase_payments_purchase_idx ON public.purchase_payments(purchase_id);

CREATE OR REPLACE FUNCTION public.record_purchase_payment(
  _purchase_id uuid, _amount numeric, _method text DEFAULT NULL, _paid_at date DEFAULT CURRENT_DATE, _notes text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE _profile uuid := public.current_profile_id(); _p public.purchases; _due numeric; _id uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF _p.status = 'cancelled' THEN RAISE EXCEPTION 'This purchase is cancelled'; END IF;
  IF COALESCE(_amount,0) <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  PERFORM public.assert_period_open(_p.company_id, COALESCE(_paid_at, CURRENT_DATE));

  _due := round(_p.total - _p.returned_amount - _p.paid_amount, 2);
  IF round(_amount,2) > _due THEN
    RAISE EXCEPTION 'Payment exceeds the remaining balance (%)', _due;
  END IF;

  INSERT INTO public.purchase_payments (company_id, purchase_id, amount, method, paid_at, notes, created_by)
  VALUES (_p.company_id, _purchase_id, round(_amount,2), NULLIF(_method,''), COALESCE(_paid_at, CURRENT_DATE), NULLIF(_notes,''), _profile)
  RETURNING id INTO _id;

  UPDATE public.purchases SET paid_amount = round(paid_amount + round(_amount,2), 2) WHERE id = _purchase_id;

  PERFORM public.log_audit('purchase.payment','purchases','purchases',_purchase_id, NULL,
    jsonb_build_object('amount', round(_amount,2), 'method', _method), _notes, _p.branch_id);
  RETURN _id;
END $$;

GRANT EXECUTE ON FUNCTION public.record_purchase_payment(uuid, numeric, text, date, text) TO authenticated;

-- ============ C) PARTIAL PURCHASE RETURNS ============
CREATE TABLE IF NOT EXISTS public.purchase_returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  purchase_id uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  return_date date NOT NULL DEFAULT CURRENT_DATE,
  refund_mode text NOT NULL DEFAULT 'reduce_due' CHECK (refund_mode IN ('reduce_due','cash')),
  total numeric NOT NULL DEFAULT 0,
  reason text NOT NULL,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.purchase_return_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id uuid NOT NULL REFERENCES public.purchase_returns(id) ON DELETE CASCADE,
  purchase_item_id uuid NOT NULL REFERENCES public.purchase_items(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.inventory_items(id),
  quantity numeric NOT NULL CHECK (quantity > 0),
  unit_cost numeric NOT NULL DEFAULT 0,
  line_total numeric NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.purchase_returns TO authenticated;
GRANT ALL ON public.purchase_returns TO service_role;
GRANT SELECT ON public.purchase_return_items TO authenticated;
GRANT ALL ON public.purchase_return_items TO service_role;

ALTER TABLE public.purchase_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "purchase_returns_view" ON public.purchase_returns;
CREATE POLICY "purchase_returns_view" ON public.purchase_returns
FOR SELECT TO authenticated
USING (company_id = public.current_company_id()
  AND (public.has_permission('purchases.view') OR public.has_permission('purchases.create') OR public.is_super_admin()));

DROP POLICY IF EXISTS "purchase_return_items_view" ON public.purchase_return_items;
CREATE POLICY "purchase_return_items_view" ON public.purchase_return_items
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.purchase_returns pr
  WHERE pr.id = purchase_return_items.return_id
    AND pr.company_id = public.current_company_id()
    AND (public.has_permission('purchases.view') OR public.has_permission('purchases.create') OR public.is_super_admin())
));

CREATE INDEX IF NOT EXISTS purchase_returns_purchase_idx ON public.purchase_returns(purchase_id);
CREATE INDEX IF NOT EXISTS purchase_return_items_return_idx ON public.purchase_return_items(return_id);

CREATE OR REPLACE FUNCTION public.return_purchase_items(
  _purchase_id uuid, _items jsonb, _reason text,
  _refund_mode text DEFAULT 'reduce_due', _return_date date DEFAULT CURRENT_DATE)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _profile uuid := public.current_profile_id();
  _p public.purchases; _ret uuid; _it jsonb; _pi public.purchase_items;
  _qty numeric; _already numeric; _total numeric := 0; _mode text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.cancel') OR public.has_permission('purchases.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'No items to return'; END IF;
  _mode := COALESCE(NULLIF(_refund_mode,''), 'reduce_due');
  IF _mode NOT IN ('reduce_due','cash') THEN RAISE EXCEPTION 'Invalid refund mode'; END IF;

  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF NOT public.can_access_branch(_p.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _p.status <> 'received' THEN RAISE EXCEPTION 'Only received purchases can be returned'; END IF;
  PERFORM public.assert_period_open(_p.company_id, COALESCE(_return_date, CURRENT_DATE));

  INSERT INTO public.purchase_returns (company_id, purchase_id, branch_id, return_date, refund_mode, reason, created_by)
  VALUES (_p.company_id, _purchase_id, _p.branch_id, COALESCE(_return_date, CURRENT_DATE), _mode, btrim(_reason), _profile)
  RETURNING id INTO _ret;

  FOR _it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _qty := COALESCE((_it->>'quantity')::numeric, 0);
    IF _qty <= 0 THEN CONTINUE; END IF;
    SELECT * INTO _pi FROM public.purchase_items
     WHERE id = NULLIF(_it->>'purchase_item_id','')::uuid AND purchase_id = _purchase_id;
    IF _pi.id IS NULL THEN RAISE EXCEPTION 'Purchase line not found'; END IF;

    SELECT COALESCE(sum(pri.quantity),0) INTO _already
      FROM public.purchase_return_items pri
      JOIN public.purchase_returns pr ON pr.id = pri.return_id
     WHERE pri.purchase_item_id = _pi.id AND pr.id <> _ret;

    IF _already + _qty > _pi.quantity THEN
      RAISE EXCEPTION 'Return quantity exceeds the purchased quantity (remaining %)', _pi.quantity - _already;
    END IF;

    INSERT INTO public.purchase_return_items (return_id, purchase_item_id, item_id, quantity, unit_cost, line_total)
    VALUES (_ret, _pi.id, _pi.item_id, _qty, _pi.unit_cost, round(_qty * _pi.unit_cost, 2));

    PERFORM public.apply_stock_movement(_p.branch_id, _pi.item_id, 'adjustment', -_qty, _pi.unit_cost,
      'Purchase return: ' || btrim(_reason), 'purchase_return', _ret);

    _total := _total + round(_qty * _pi.unit_cost, 2);
  END LOOP;

  IF _total <= 0 THEN RAISE EXCEPTION 'No valid items to return'; END IF;

  UPDATE public.purchase_returns SET total = round(_total,2) WHERE id = _ret;

  UPDATE public.purchases
     SET returned_amount = round(returned_amount + round(_total,2), 2),
         paid_amount = CASE WHEN _mode = 'cash'
                            THEN greatest(0, round(paid_amount - round(_total,2), 2))
                            ELSE paid_amount END
   WHERE id = _purchase_id;

  PERFORM public.log_audit('purchase.return','purchases','purchase_returns',_ret, NULL,
    jsonb_build_object('purchase_id', _purchase_id, 'total', round(_total,2), 'refund_mode', _mode),
    btrim(_reason), _p.branch_id);

  RETURN _ret;
END $$;

GRANT EXECUTE ON FUNCTION public.return_purchase_items(uuid, jsonb, text, text, date) TO authenticated;

-- ============ D) create_purchase: optional upfront payment ============
DROP FUNCTION IF EXISTS public.create_purchase(uuid, uuid, jsonb, text, date, numeric, numeric, text, text, boolean);

CREATE OR REPLACE FUNCTION public.create_purchase(
  _branch_id uuid, _supplier_id uuid, _items jsonb, _invoice_number text DEFAULT NULL::text,
  _purchase_date date DEFAULT CURRENT_DATE, _tax_amount numeric DEFAULT 0, _discount_amount numeric DEFAULT 0,
  _payment_method text DEFAULT NULL::text, _notes text DEFAULT NULL::text, _receive boolean DEFAULT true,
  _paid_amount numeric DEFAULT 0)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _profile uuid := public.current_profile_id();
  _company uuid := public.current_company_id();
  _purchase uuid; _it jsonb; _sub numeric := 0; _qty numeric; _cost numeric; _item public.inventory_items;
  _total numeric; _paid numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.create') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Purchase has no items'; END IF;
  IF _supplier_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.suppliers s WHERE s.id = _supplier_id AND s.company_id = _company) THEN
    RAISE EXCEPTION 'Supplier not found';
  END IF;

  INSERT INTO public.purchases (company_id, branch_id, supplier_id, invoice_number, purchase_date,
    tax_amount, discount_amount, payment_method, notes, created_by)
  VALUES (_company, _branch_id, _supplier_id, NULLIF(_invoice_number,''), COALESCE(_purchase_date, CURRENT_DATE),
    COALESCE(_tax_amount,0), COALESCE(_discount_amount,0), NULLIF(_payment_method,''), NULLIF(_notes,''), _profile)
  RETURNING id INTO _purchase;

  FOR _it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _qty := COALESCE((_it->>'quantity')::numeric, 0);
    _cost := COALESCE((_it->>'unit_cost')::numeric, 0);
    IF _qty <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than zero'; END IF;
    IF _cost < 0 THEN RAISE EXCEPTION 'Unit cost cannot be negative'; END IF;
    SELECT * INTO _item FROM public.inventory_items
    WHERE id = NULLIF(_it->>'item_id','')::uuid AND company_id = _company AND is_active;
    IF _item.id IS NULL THEN RAISE EXCEPTION 'Inventory item not found'; END IF;

    INSERT INTO public.purchase_items (purchase_id, item_id, quantity, unit_cost, line_total)
    VALUES (_purchase, _item.id, _qty, _cost, round(_qty * _cost, 2));
    _sub := _sub + round(_qty * _cost, 2);
  END LOOP;

  IF COALESCE(_discount_amount,0) > _sub THEN RAISE EXCEPTION 'Discount exceeds purchase subtotal'; END IF;

  _total := round(_sub - COALESCE(_discount_amount,0) + COALESCE(_tax_amount,0), 2);

  UPDATE public.purchases
     SET subtotal = round(_sub,2), total = _total
   WHERE id = _purchase;

  PERFORM public.log_audit('purchase.create','purchases','purchases',_purchase,NULL,
    jsonb_build_object('subtotal',_sub,'supplier_id',_supplier_id),NULL,_branch_id);

  IF COALESCE(_receive, true) THEN PERFORM public.receive_purchase(_purchase); END IF;

  _paid := round(COALESCE(_paid_amount,0), 2);
  IF _paid > 0 THEN
    IF _paid > _total THEN RAISE EXCEPTION 'Paid amount exceeds the purchase total'; END IF;
    PERFORM public.record_purchase_payment(_purchase, _paid, _payment_method, COALESCE(_purchase_date, CURRENT_DATE), 'Paid on purchase creation');
  END IF;

  RETURN _purchase;
END $function$;

GRANT EXECUTE ON FUNCTION public.create_purchase(uuid, uuid, jsonb, text, date, numeric, numeric, text, text, boolean, numeric) TO authenticated;