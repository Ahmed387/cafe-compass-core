REVOKE EXECUTE ON FUNCTION public.mark_order_delivered(uuid) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.refund_order_items(uuid, jsonb, text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.mark_order_delivered(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refund_order_items(uuid, jsonb, text, text) TO authenticated;