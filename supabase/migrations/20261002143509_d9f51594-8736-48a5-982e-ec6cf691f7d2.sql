CREATE OR REPLACE FUNCTION public.consume_recipe_on_sale()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _branch uuid; _r record;
BEGIN
  SELECT o.branch_id INTO _branch FROM public.orders o WHERE o.id = NEW.order_id;
  IF _branch IS NULL OR NEW.product_id IS NULL THEN RETURN NEW; END IF;
  FOR _r IN
    SELECT pr.item_id, pr.quantity FROM public.product_recipes pr
    WHERE pr.product_id = NEW.product_id AND (pr.size_id IS NULL OR pr.size_id = NEW.size_id)
  LOOP
    PERFORM public.apply_stock_movement(_branch, _r.item_id, 'sale_consumption',
      -round(_r.quantity * 1.05 * NEW.quantity, 4), NULL, NULL, 'order_item', NEW.id);
  END LOOP;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.consume_modifier_recipe_on_sale()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _branch uuid; _qty int; _r record;
BEGIN
  IF NEW.option_id IS NULL THEN RETURN NEW; END IF;
  SELECT o.branch_id, oi.quantity INTO _branch, _qty
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id WHERE oi.id = NEW.order_item_id;
  IF _branch IS NULL THEN RETURN NEW; END IF;
  FOR _r IN SELECT mr.item_id, mr.quantity FROM public.modifier_option_recipes mr WHERE mr.option_id = NEW.option_id LOOP
    PERFORM public.apply_stock_movement(_branch, _r.item_id, 'sale_consumption',
      -round(_r.quantity * 1.05 * COALESCE(_qty,1), 4), NULL, NULL, 'order_item', NEW.order_item_id);
  END LOOP;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.check_order_stock(_branch_id uuid, _items jsonb)
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _item jsonb; _mod jsonb; _r record; _needed jsonb := '{}'::jsonb; _key text; _qty numeric; _pid uuid; _pname text;
  _override boolean;
BEGIN
  _override := EXISTS (SELECT 1 FROM public.stock_overrides o
    WHERE o.profile_id = public.current_profile_id() AND o.branch_id = _branch_id AND o.expires_at > now());
  FOR _item IN SELECT * FROM jsonb_array_elements(COALESCE(_items,'[]'::jsonb)) LOOP
    _pid := NULLIF(_item->>'product_id','')::uuid;
    IF _pid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = _pid)
       AND NOT EXISTS (SELECT 1 FROM public.products px WHERE px.id = _pid AND NOT px.track_stock) THEN
      SELECT COALESCE(p.name_ar, p.name) INTO _pname FROM public.products p WHERE p.id = _pid;
      RAISE EXCEPTION 'RECIPE_MISSING: % — هذا المنتج بدون وصفة مخزنية، يرجى إضافة الوصفة أولاً من صفحة المخزون', COALESCE(_pname,'');
    END IF;
    IF _override THEN CONTINUE; END IF;
    FOR _r IN
      SELECT pr.item_id, pr.quantity * 1.05 * COALESCE((_item->>'quantity')::numeric,0) AS need
      FROM public.product_recipes pr
      WHERE pr.product_id = _pid AND (pr.size_id IS NULL OR pr.size_id = NULLIF(_item->>'size_id','')::uuid)
    LOOP
      _key := _r.item_id::text;
      _needed := jsonb_set(_needed, ARRAY[_key], to_jsonb(COALESCE((_needed->>_key)::numeric,0) + _r.need), true);
    END LOOP;
    IF _item ? 'modifiers' THEN
      FOR _mod IN SELECT * FROM jsonb_array_elements(_item->'modifiers') LOOP
        FOR _r IN
          SELECT mr.item_id, mr.quantity * 1.05 * COALESCE((_item->>'quantity')::numeric,0) AS need
          FROM public.modifier_option_recipes mr WHERE mr.option_id = NULLIF(_mod->>'option_id','')::uuid
        LOOP
          _key := _r.item_id::text;
          _needed := jsonb_set(_needed, ARRAY[_key], to_jsonb(COALESCE((_needed->>_key)::numeric,0) + _r.need), true);
        END LOOP;
      END LOOP;
    END IF;
  END LOOP;
  IF _override THEN RETURN; END IF;
  FOR _r IN SELECT key::uuid AS item_id, value::numeric AS need FROM jsonb_each_text(_needed) LOOP
    SELECT COALESCE(bs.quantity,0) INTO _qty FROM public.branch_stock bs WHERE bs.item_id = _r.item_id AND bs.branch_id = _branch_id;
    IF COALESCE(_qty,0) < round(_r.need, 4) THEN
      RAISE EXCEPTION 'Not enough stock available for %', (SELECT name FROM public.inventory_items WHERE id = _r.item_id);
    END IF;
  END LOOP;
END $function$;

CREATE OR REPLACE FUNCTION public.reopen_accounting_period(_period_id uuid, _reason text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods; _old public.profit_distributions;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can reopen a period'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Period is not closed'; END IF;

  -- Append-only reversal of the active distribution (same path as relock)
  FOR _old IN SELECT * FROM public.profit_distributions WHERE period_id=_period_id AND status='active' LOOP
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,reversal_of,created_by)
    SELECT company_id,partner_id,'adjustment',-amount,currency,'profit_distribution_reversal',_old.id,'عكس توزيع أرباح بسبب إعادة فتح الفترة',transaction_date,'active',id,_profile
      FROM public.partner_ledger_transactions WHERE reference_id=_old.id AND status='active'
       AND reference_type IN ('profit_distribution','partner_tab');
    UPDATE public.partner_tab_orders SET is_settled=false, settled_at=NULL, distribution_id=NULL WHERE distribution_id=_old.id;
    UPDATE public.profit_distributions SET status='reversed' WHERE id=_old.id;
  END LOOP;

  UPDATE public.accounting_periods SET status = 'open', closed_at = NULL, closed_by = NULL, override_until = NULL WHERE id = _period_id;
  PERFORM public.log_audit('period.reopen','finance','accounting_periods',_period_id,
    jsonb_build_object('status','closed','reversed_distribution',_old.id), jsonb_build_object('status','open'), _reason, NULL);
  RETURN _period_id;
END $function$;