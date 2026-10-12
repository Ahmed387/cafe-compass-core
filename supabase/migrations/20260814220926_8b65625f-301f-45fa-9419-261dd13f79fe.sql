CREATE UNIQUE INDEX IF NOT EXISTS user_profiles_auth_user_id_key ON public.user_profiles(auth_user_id);
CREATE INDEX IF NOT EXISTS orders_company_created_idx ON public.orders(company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_branch_created_idx ON public.orders(branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS order_items_product_idx ON public.order_items(product_id);
CREATE INDEX IF NOT EXISTS order_items_order_idx ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS order_payments_order_idx ON public.order_payments(order_id);
CREATE INDEX IF NOT EXISTS stock_movements_item_branch_idx ON public.stock_movements(item_id, branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS salary_payments_company_period_idx ON public.salary_payments(company_id, period_start);
CREATE INDEX IF NOT EXISTS expenses_company_date_idx ON public.expenses(company_id, expense_date);

ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_quantity_positive CHECK (quantity > 0) NOT VALID;
ALTER TABLE public.order_items VALIDATE CONSTRAINT order_items_quantity_positive;

ALTER TABLE public.order_payments
  ADD CONSTRAINT order_payments_amount_positive CHECK (amount > 0) NOT VALID;
ALTER TABLE public.order_payments VALIDATE CONSTRAINT order_payments_amount_positive;

ALTER TABLE public.orders
  ADD CONSTRAINT orders_discount_within_subtotal CHECK (discount_amount >= 0 AND discount_amount <= subtotal) NOT VALID;
ALTER TABLE public.orders VALIDATE CONSTRAINT orders_discount_within_subtotal;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_cost_nonnegative CHECK (unit_cost >= 0) NOT VALID;
ALTER TABLE public.stock_movements VALIDATE CONSTRAINT stock_movements_cost_nonnegative;

ALTER TABLE public.inventory_items
  ADD CONSTRAINT inventory_items_cost_nonnegative CHECK (cost_per_unit >= 0) NOT VALID;
ALTER TABLE public.inventory_items VALIDATE CONSTRAINT inventory_items_cost_nonnegative;

REVOKE ALL ON FUNCTION public.apply_stock_movement(uuid, uuid, stock_movement_type, numeric, numeric, text, text, uuid) FROM anon, public, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_stock_movement(uuid, uuid, stock_movement_type, numeric, numeric, text, text, uuid) TO service_role;
