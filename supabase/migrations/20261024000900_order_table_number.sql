-- Table number on dine-in orders (Ahmed, 2026-10-24).
-- * orders.table_number: typed by the cashier (any number), kept only for
--   dine-in. Required for dine-in in the POS; old orders stay empty.
-- * create_pos_order_with_table: the POS calls it; it refuses a dine-in
--   order without a table, then calls create_pos_order unchanged (a POS tab
--   still on the old screen keeps working).
-- * set_order_table: change it later. The cashier can while the order's
--   shift is open; a manager (shifts.close) or the super admin any time.
--   Every change is in the audit log. No data is deleted.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS table_number text;
DO $c$ BEGIN
  ALTER TABLE public.orders ADD CONSTRAINT orders_table_number_len CHECK (table_number IS NULL OR length(table_number) BETWEEN 1 AND 20);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- create_pos_order stays exactly as it is; the POS calls this wrapper, which
-- creates the order the same way and then stores the table number.
CREATE OR REPLACE FUNCTION public.create_pos_order_with_table(
  _branch_id uuid, _items jsonb, _payments jsonb, _order_type order_type DEFAULT 'takeaway'::order_type,
  _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL::text, _customer_name text DEFAULT NULL::text,
  _customer_phone text DEFAULT NULL::text, _notes text DEFAULT NULL::text, _customer_id uuid DEFAULT NULL::uuid,
  _voucher_code text DEFAULT NULL::text, _partner_id uuid DEFAULT NULL::uuid, _on_partner_tab boolean DEFAULT false,
  _table_number text DEFAULT NULL::text)
RETURNS TABLE(out_id uuid, out_number text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _id uuid; _num text; _table text := left(NULLIF(btrim(COALESCE(_table_number, '')), ''), 20);
BEGIN
  IF _order_type = 'dine_in' AND _table IS NULL THEN RAISE EXCEPTION 'Table number is required'; END IF;
  SELECT c.out_id, c.out_number INTO _id, _num
    FROM public.create_pos_order(_branch_id, _items, _payments, _order_type, _discount_amount, _discount_reason,
      _customer_name, _customer_phone, _notes, _customer_id, _voucher_code, _partner_id, _on_partner_tab) c;
  IF _order_type = 'dine_in' THEN
    UPDATE public.orders SET table_number = _table WHERE id = _id;
  END IF;
  RETURN QUERY SELECT _id, _num;
END $function$;
REVOKE EXECUTE ON FUNCTION public.create_pos_order_with_table(uuid,jsonb,jsonb,order_type,numeric,text,text,text,text,uuid,text,uuid,boolean,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_pos_order_with_table(uuid,jsonb,jsonb,order_type,numeric,text,text,text,text,uuid,text,uuid,boolean,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_order_table(_order_id uuid, _table_number text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _o public.orders; _open boolean; _new text := left(NULLIF(btrim(COALESCE(_table_number, '')), ''), 20);
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _o FROM public.orders WHERE id = _order_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF _o.order_type <> 'dine_in' THEN RAISE EXCEPTION 'Table number is only for dine-in orders'; END IF;
  IF _new IS NULL THEN RAISE EXCEPTION 'Table number is required'; END IF;
  SELECT s.status = 'open' INTO _open FROM public.shifts s WHERE s.id = _o.shift_id;
  IF NOT (public.is_super_admin() OR public.has_permission('shifts.close')
          OR (COALESCE(_open, false) AND public.has_permission('pos.create_order'))) THEN
    RAISE EXCEPTION 'Only a manager can change the table after the shift is closed';
  END IF;
  IF _new IS NOT DISTINCT FROM _o.table_number THEN RETURN; END IF;
  UPDATE public.orders SET table_number = _new, updated_at = now() WHERE id = _o.id;
  PERFORM public.log_audit('order.table_change', 'orders', 'orders', _o.id,
    jsonb_build_object('table_number', _o.table_number), jsonb_build_object('table_number', _new), NULL, NULL);
END $function$;
REVOKE EXECUTE ON FUNCTION public.set_order_table(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_table(uuid, text) TO authenticated;
