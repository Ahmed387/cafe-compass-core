ALTER TABLE public.order_refunds DISABLE TRIGGER USER;
ALTER TABLE public.order_payments DISABLE TRIGGER USER;
ALTER TABLE public.order_items DISABLE TRIGGER USER;
ALTER TABLE public.orders DISABLE TRIGGER USER;
ALTER TABLE public.stock_movements DISABLE TRIGGER USER;
ALTER TABLE public.shifts DISABLE TRIGGER USER;
ALTER TABLE public.customer_points_transactions DISABLE TRIGGER USER;

DELETE FROM public.order_item_modifiers;
DELETE FROM public.order_refunds;
DELETE FROM public.order_payments;
DELETE FROM public.stock_movements;
DELETE FROM public.order_items;
DELETE FROM public.customer_points_transactions;
DELETE FROM public.orders;
DELETE FROM public.shifts;
UPDATE public.branch_stock SET quantity = 0;
DELETE FROM public.order_counters;

ALTER TABLE public.order_refunds ENABLE TRIGGER USER;
ALTER TABLE public.order_payments ENABLE TRIGGER USER;
ALTER TABLE public.order_items ENABLE TRIGGER USER;
ALTER TABLE public.orders ENABLE TRIGGER USER;
ALTER TABLE public.stock_movements ENABLE TRIGGER USER;
ALTER TABLE public.shifts ENABLE TRIGGER USER;
ALTER TABLE public.customer_points_transactions ENABLE TRIGGER USER;