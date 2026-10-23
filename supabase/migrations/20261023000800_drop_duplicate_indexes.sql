SET lock_timeout = '10s';

-- Duplicate indexes: each one has an identical twin on the same columns,
-- so dropping them loses nothing and makes writes a little cheaper.
DROP INDEX IF EXISTS public.idx_order_items_order;
DROP INDEX IF EXISTS public.idx_order_payments_order;
DROP INDEX IF EXISTS public.idx_order_refunds_order;
DROP INDEX IF EXISTS public.idx_orders_branch_created_at;
DROP INDEX IF EXISTS public.idx_orders_company_created_at;
DROP INDEX IF EXISTS public.idx_stock_moves_item;
