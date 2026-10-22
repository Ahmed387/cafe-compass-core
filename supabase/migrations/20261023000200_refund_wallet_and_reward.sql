-- Refunds now:
--  * give the wallet-paid part of a bill back to the customer's wallet (not as cash),
--  * take back a cashback reward the refunded spend had earned: from the wallet
--    first, and if the customer already spent it, out of the cash refund,
--  * mark a bill that is only partly returned as partially_refunded.

CREATE OR REPLACE FUNCTION public.refund_order_items(_order_id uuid, _items jsonb, _method_key text DEFAULT 'cash'::text, _reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _profile uuid := public.current_profile_id();
  _o public.orders;
  _entry jsonb;
  _r record;
  _item_id uuid;
  _qty int;
  _disposition text;
  _oi public.order_items;
  _refunded_qty int;
  _remaining_qty int;
  _line_gross numeric := 0;
  _amount numeric := 0;
  _paid numeric;
  _points_paid numeric;
  _cash_left numeric;
  _wallet_left numeric;
  _ratio numeric;
  _share numeric;
  _wallet_part numeric := 0;
  _payload jsonb := '[]'::jsonb;
  _refund_id uuid;
  _tax_share numeric := 0;
  _is_tab boolean := false;
  -- cashback reversal
  _cfg jsonb;
  _tiers jsonb;
  _n int;
  _progress numeric;
  _level int;
  _earned_left numeric := 0;
  _claw numeric := 0;
  _step numeric;
  _guard int := 0;
  _bal numeric;
  _from_wallet numeric := 0;
  _withheld numeric := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'No refund items provided'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_refund_order(_o) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  PERFORM public._assert_order_shift_open(_o);
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status NOT IN ('completed','partially_refunded') THEN
    RAISE EXCEPTION 'Only delivered orders can be refunded';
  END IF;

  SELECT COALESCE(SUM(amount),0), COALESCE(SUM(amount) FILTER (WHERE public.tender_key(method_key) = 'points'),0)
    INTO _paid, _points_paid FROM public.order_payments WHERE order_id = _order_id;
  -- A partner-tab invoice is "paid" by the tab: refunds come off the tab, never the drawer.
  IF _paid = 0 AND EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = _order_id) THEN
    _paid := _o.total;
    _points_paid := 0;
    _method_key := 'partner_tab';
    _is_tab := true;
  END IF;
  SELECT round(_paid - _points_paid - COALESCE(SUM(amount + cash_withheld),0), 2),
         round(_points_paid - COALESCE(SUM(wallet_amount),0), 2)
    INTO _cash_left, _wallet_left
    FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  IF _cash_left + _wallet_left <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;

  -- Pass 1: validate every entry and compute the gross refund value.
  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _item_id := NULLIF(_entry->>'order_item_id','')::uuid;
    _qty := COALESCE((_entry->>'quantity')::int, 0);
    _disposition := COALESCE(NULLIF(_entry->>'disposition',''), 'restock');
    IF _disposition NOT IN ('restock','waste') THEN RAISE EXCEPTION 'Invalid disposition'; END IF;
    IF _qty <= 0 THEN RAISE EXCEPTION 'Refund quantity must be greater than zero'; END IF;

    SELECT * INTO _oi FROM public.order_items
    WHERE id = _item_id AND order_id = _order_id;
    IF _oi.id IS NULL THEN RAISE EXCEPTION 'Order line not found'; END IF;
    IF _oi.status = 'voided' THEN RAISE EXCEPTION 'Line % is already voided', _oi.product_name; END IF;

    SELECT COALESCE(SUM((e->>'quantity')::int),0) INTO _refunded_qty
    FROM public.order_refunds r,
         jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) e
    WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'
      AND e->>'order_item_id' = _item_id::text;

    _remaining_qty := _oi.quantity - _refunded_qty;
    IF _qty > _remaining_qty THEN
      RAISE EXCEPTION 'Cannot refund more than the remaining % on %', _remaining_qty, _oi.product_name;
    END IF;

    _line_gross := _line_gross + round((COALESCE(_oi.unit_price,0) + COALESCE(_oi.modifiers_total,0)) * _qty, 2);
  END LOOP;

  IF _line_gross <= 0 THEN RAISE EXCEPTION 'Nothing to refund'; END IF;

  -- Proportional share of the invoice total (discount + tax included), split
  -- between the wallet-paid and the cash-paid part of the bill.
  _ratio := CASE WHEN COALESCE(_o.subtotal,0) > 0 THEN _o.total / _o.subtotal ELSE 1 END;
  _share := round(_line_gross * _ratio, 2);
  IF _points_paid > 0 AND _paid > 0 THEN
    _wallet_part := GREATEST(LEAST(round(_share * _points_paid / _paid, 2), _wallet_left), 0);
  END IF;
  _amount := GREATEST(LEAST(round(_share - _wallet_part, 2), _cash_left), 0);
  _share := round(_amount + _wallet_part, 2);

  IF _paid > 0 AND COALESCE(_o.tax_amount,0) > 0 THEN
    _tax_share := round(_o.tax_amount * LEAST(_share / _paid, 1), 2);
  END IF;

  -- Pass 2: stock side-effects + payload.
  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _item_id := NULLIF(_entry->>'order_item_id','')::uuid;
    _qty := (_entry->>'quantity')::int;
    _disposition := COALESCE(NULLIF(_entry->>'disposition',''), 'restock');
    SELECT * INTO _oi FROM public.order_items WHERE id = _item_id;

    IF _disposition = 'restock' THEN
      IF _qty = _oi.quantity THEN
        PERFORM public.return_line_stock(_item_id);
      ELSE
        FOR _r IN SELECT sm.item_id, sm.quantity, sm.branch_id
                  FROM public.stock_movements sm
                  WHERE sm.reference_type = 'order_item'
                    AND sm.movement_type = 'sale_consumption'
                    AND sm.reference_id = _item_id
        LOOP
          PERFORM public.apply_stock_movement(_r.branch_id, _r.item_id, 'sale_return',
            -round(_r.quantity * _qty / _oi.quantity, 3), NULL,
            'Partial item refund (restock)', 'order_item', _item_id);
        END LOOP;
      END IF;
    END IF;
    -- Waste: ingredients were consumed at sale time; stock stays as-is.
    -- The loss is recorded in items_payload and surfaced on the shift waste card.

    _payload := _payload || jsonb_build_object(
      'order_item_id', _item_id,
      'product_name', _oi.product_name,
      'quantity', _qty,
      'unit_price', COALESCE(_oi.unit_price,0),
      'unit_cost', COALESCE(_oi.unit_cost,0),
      'line_gross', round((COALESCE(_oi.unit_price,0) + COALESCE(_oi.modifiers_total,0)) * _qty, 2),
      'disposition', _disposition);
  END LOOP;

  -- Cashback: the refunded cash spend leaves the cycle; any level it had
  -- reached on this bill is undone and its reward taken back.
  IF _o.customer_id IS NOT NULL AND NOT _is_tab THEN
    _cfg := public.cashback_config(_o.company_id);
    _tiers := COALESCE(_cfg->'tiers', '[]'::jsonb);
    _n := jsonb_array_length(_tiers);
    SELECT round(cashback_progress - _amount, 2), GREATEST(cashback_level, 0), wallet_balance
      INTO _progress, _level, _bal FROM public.customers WHERE id = _o.customer_id FOR UPDATE;

    SELECT COALESCE(SUM(amount), 0) INTO _earned_left FROM public.customer_wallet_transactions
     WHERE order_id = _order_id AND kind = 'earn';
    SELECT round(_earned_left - COALESCE(SUM(reward_clawback), 0), 2) INTO _earned_left
      FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';

    WHILE _earned_left > 0 AND _n > 0 LOOP
      _guard := _guard + 1;
      EXIT WHEN _guard > 1000;
      IF _level = 0 AND _progress < 0 THEN
        -- The bill had completed the last level and restarted the cycle.
        _progress := round(_progress + (_tiers->(_n - 1)->>'target')::numeric, 2);
        _level := _n - 1;
      ELSIF _level > 0 AND _level <= _n AND _progress < (_tiers->(_level - 1)->>'target')::numeric THEN
        _level := _level - 1;
      ELSE
        EXIT;
      END IF;
      _step := LEAST((_tiers->_level->>'reward')::numeric, _earned_left);
      _claw := round(_claw + _step, 2);
      _earned_left := round(_earned_left - _step, 2);
    END LOOP;
    _progress := GREATEST(_progress, 0);

    -- Wallet first (after the wallet-paid part comes back), the rest out of the cash refund.
    _from_wallet := LEAST(_claw, round(COALESCE(_bal, 0) + _wallet_part, 2));
    _withheld := LEAST(round(_claw - _from_wallet, 2), _amount);
    _claw := round(_from_wallet + _withheld, 2);
    _amount := round(_amount - _withheld, 2);

    UPDATE public.customers SET cashback_progress = _progress, cashback_level = _level,
           total_spent = GREATEST(COALESCE(total_spent, 0) - _share, 0), updated_at = now()
     WHERE id = _o.customer_id;
  ELSIF _o.customer_id IS NOT NULL THEN
    UPDATE public.customers SET total_spent = GREATEST(COALESCE(total_spent, 0) - _share, 0), updated_at = now()
     WHERE id = _o.customer_id;
  END IF;

  INSERT INTO public.order_refunds
    (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount, method_key,
     reason, status, origin, items_payload, created_by,
     wallet_amount, reward_clawback, cash_withheld, cashback_done)
  VALUES
    (_o.company_id, _o.branch_id, _o.id, public.refund_shift_for(_o, _method_key), 'partial', _amount, _tax_share,
     COALESCE(NULLIF(_method_key,''),'cash'), _reason, 'active', 'manual', _payload, _profile,
     _wallet_part, _claw, _withheld, true)
  RETURNING id INTO _refund_id;

  IF _wallet_part > 0 THEN
    PERFORM public._wallet_post(_o.company_id, _o.customer_id, _o.id, 'refund', _wallet_part,
      'رجوع المدفوع من المحفظة — مرتجع فاتورة #' || COALESCE(_o.order_number, ''), _profile);
  END IF;
  IF _from_wallet > 0 THEN
    PERFORM public._wallet_post(_o.company_id, _o.customer_id, _o.id, 'adjust', -_from_wallet,
      'سحب مكافأة الكاش باك — مرتجع فاتورة #' || COALESCE(_o.order_number, ''), _profile);
  END IF;

  PERFORM public.log_audit('order.refund_items', 'pos', 'orders', _order_id,
    jsonb_build_object('paid', _paid, 'wallet_paid', _points_paid, 'cash_left_before', _cash_left, 'wallet_left_before', _wallet_left),
    jsonb_build_object('refund_id', _refund_id, 'amount', _amount, 'wallet_amount', _wallet_part,
      'reward_clawback', _claw, 'cash_withheld', _withheld, 'items', _payload),
    _reason, _o.branch_id);

  RETURN jsonb_build_object('refund_id', _refund_id, 'amount', _amount, 'kind', 'partial',
    'wallet_amount', _wallet_part, 'reward_clawback', _claw, 'cash_withheld', _withheld,
    'reward_from_wallet', _from_wallet);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.refund_order_items(uuid, jsonb, text, text) FROM PUBLIC, anon, authenticated;

-- Rows written by refund_order_items already moved the wallet and the cycle.
CREATE OR REPLACE FUNCTION public.trg_refund_cashback()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _cust uuid; _number text;
BEGIN
  IF NEW.status <> 'active' OR NEW.cashback_done THEN RETURN NEW; END IF;
  SELECT customer_id, order_number INTO _cust, _number FROM public.orders WHERE id = NEW.order_id;
  IF _cust IS NULL THEN RETURN NEW; END IF;
  IF public.tender_key(NEW.method_key) = 'points' THEN
    PERFORM public._wallet_post(NEW.company_id, _cust, NEW.order_id, 'refund', NEW.amount,
      'رجوع كاش باك من مرتجع — فاتورة #' || COALESCE(_number, ''), NEW.created_by);
  ELSIF public.tender_key(NEW.method_key) <> 'partner_tab' THEN
    UPDATE public.customers SET cashback_progress = GREATEST(round(cashback_progress - NEW.amount, 2), 0) WHERE id = _cust;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.refund_order_items_attributed(_order_id uuid, _items jsonb, _method_key text, _reason text, _fault text, _staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _res jsonb; _ref public.order_refunds; _paid numeric; _already numeric; _left_qty numeric;
BEGIN
  -- 'business' and 'venue' mean the same: the café absorbs it.
  _fault := CASE WHEN _fault = 'business' THEN 'venue' ELSE _fault END;
  IF _fault IS NULL OR _fault NOT IN ('staff', 'venue', 'all_staff') THEN RAISE EXCEPTION 'Refund attribution is required'; END IF;
  IF _fault = 'staff' AND _staff_id IS NULL THEN RAISE EXCEPTION 'Select the responsible staff member'; END IF;
  _res := public.refund_order_items(_order_id, _items, COALESCE(_method_key, 'cash'), _reason);
  SELECT * INTO _ref FROM public.order_refunds WHERE id = (_res->>'refund_id')::uuid;
  IF _fault = 'staff' AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _staff_id AND company_id = _ref.company_id) THEN
    RAISE EXCEPTION 'Invalid staff member';
  END IF;
  UPDATE public.order_refunds SET fault = _fault, blamed_staff_id = CASE WHEN _fault = 'staff' THEN _staff_id END
   WHERE id = _ref.id;
  IF _fault IN ('staff', 'all_staff') THEN
    -- The staff pays for what went back to the customer (cash + wallet).
    PERFORM public._charge_staff(_ref.company_id, round(_ref.amount + _ref.wallet_amount, 2), _fault, _staff_id,
      'خطأ موظف — مرتجع: ' || _reason, _order_id, _ref.shift_id, 'refund');
  END IF;

  -- Nothing left to give back → the bill is fully returned; otherwise partly.
  _paid := public._order_paid_total(_order_id);
  SELECT COALESCE(SUM(amount + wallet_amount + cash_withheld), 0) INTO _already
    FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  SELECT COALESCE(SUM(oi.quantity), 0) - COALESCE((
           SELECT SUM((e->>'quantity')::numeric) FROM public.order_refunds r
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload, '[]'::jsonb)) e
            WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'), 0)
    INTO _left_qty FROM public.order_items oi WHERE oi.order_id = _order_id AND oi.status = 'active';
  IF round(_paid - _already, 2) <= 0 OR _left_qty <= 0 THEN
    UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;
    _res := _res || jsonb_build_object('kind', 'full', 'status', 'refunded');
  ELSE
    UPDATE public.orders SET status = 'partially_refunded', updated_at = now()
     WHERE id = _order_id AND status = 'completed';
    _res := _res || jsonb_build_object('status', 'partially_refunded');
  END IF;
  RETURN _res;
END $function$;

CREATE OR REPLACE FUNCTION public.refund_order_full(_order_id uuid, _reason text, _method_key text DEFAULT 'cash'::text, _fault text DEFAULT 'venue'::text, _staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _o public.orders; _items jsonb := '[]'::jsonb; _r record; _res jsonb; _ref_id uuid;
  _paid numeric; _points_paid numeric; _cash_left numeric; _wallet_left numeric; _ref public.order_refunds;
BEGIN
  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF _o.status NOT IN ('completed', 'partially_refunded') THEN
    RAISE EXCEPTION 'Only delivered orders can be returned';
  END IF;

  FOR _r IN
    SELECT oi.id, oi.quantity - COALESCE((
             SELECT SUM((e->>'quantity')::int) FROM public.order_refunds r
              CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload, '[]'::jsonb)) e
              WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'
                AND e->>'order_item_id' = oi.id::text), 0) AS left_qty
      FROM public.order_items oi
     WHERE oi.order_id = _order_id AND oi.status = 'active'
  LOOP
    IF _r.left_qty > 0 THEN
      _items := _items || jsonb_build_object('order_item_id', _r.id, 'quantity', _r.left_qty, 'disposition', 'restock');
    END IF;
  END LOOP;
  IF jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Everything on this invoice was already returned'; END IF;

  _res := public.refund_order_items_attributed(_order_id, _items, _method_key, _reason, _fault, _staff_id);
  _ref_id := (_res->>'refund_id')::uuid;

  -- The proportional share can round a piastre short; give back the exact rest
  -- on each side (cash and wallet).
  _paid := public._order_paid_total(_order_id);
  SELECT COALESCE(SUM(amount) FILTER (WHERE public.tender_key(method_key) = 'points'), 0)
    INTO _points_paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT round(_paid - _points_paid - COALESCE(SUM(amount + cash_withheld), 0), 2),
         round(_points_paid - COALESCE(SUM(wallet_amount), 0), 2)
    INTO _cash_left, _wallet_left
    FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  IF _cash_left > 0 THEN
    UPDATE public.order_refunds SET amount = round(amount + _cash_left, 2) WHERE id = _ref_id;
    UPDATE public.staff_penalties SET amount = round(amount + _cash_left, 2)
     WHERE id = (SELECT id FROM public.staff_penalties
                  WHERE order_id = _order_id AND source = 'refund' AND created_at = now()
                  ORDER BY created_at DESC, amount DESC LIMIT 1);
  END IF;
  IF _wallet_left > 0 AND _o.customer_id IS NOT NULL THEN
    UPDATE public.order_refunds SET wallet_amount = round(wallet_amount + _wallet_left, 2) WHERE id = _ref_id;
    PERFORM public._wallet_post(_o.company_id, _o.customer_id, _o.id, 'refund', _wallet_left,
      'رجوع المدفوع من المحفظة — مرتجع فاتورة #' || COALESCE(_o.order_number, ''), public.current_profile_id());
  END IF;
  UPDATE public.order_refunds SET kind = 'full' WHERE id = _ref_id;
  UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;

  PERFORM public.log_audit('order.refund_full', 'pos', 'orders', _order_id, jsonb_build_object('status', _o.status),
    jsonb_build_object('status', 'refunded', 'refund_id', _ref_id, 'items', _items), _reason, _o.branch_id);
  SELECT * INTO _ref FROM public.order_refunds WHERE id = _ref_id;
  RETURN _res || jsonb_build_object('kind', 'full', 'status', 'refunded', 'amount', _ref.amount,
    'wallet_amount', _ref.wallet_amount, 'reward_clawback', _ref.reward_clawback, 'cash_withheld', _ref.cash_withheld);
END $function$;
