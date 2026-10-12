-- Golden Matrix Parts 4-8: order lifecycle + item-level refunds + staff penalties

-- (1) New order lifecycle statuses
ALTER TYPE public.order_status ADD VALUE IF NOT EXISTS 'pending';
ALTER TYPE public.order_status ADD VALUE IF NOT EXISTS 'partially_refunded';

-- (2) Item-level refund payloads
ALTER TABLE public.order_refunds ADD COLUMN IF NOT EXISTS items_payload jsonb;

-- (3) Staff penalties linked to payroll
CREATE TABLE IF NOT EXISTS public.staff_penalties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  reason text NOT NULL,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  is_settled boolean NOT NULL DEFAULT false,
  payroll_id uuid REFERENCES public.salary_payments(id) ON DELETE SET NULL,
  created_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.staff_penalties TO authenticated;
GRANT ALL ON public.staff_penalties TO service_role;
ALTER TABLE public.staff_penalties ENABLE ROW LEVEL SECURITY;

CREATE POLICY "staff_penalties_select"
  ON public.staff_penalties FOR SELECT TO authenticated
  USING (public.current_company_id() = company_id);

CREATE POLICY "staff_penalties_insert"
  ON public.staff_penalties FOR INSERT TO authenticated
  WITH CHECK (
    (public.is_super_admin() OR public.has_permission('payroll.manage'))
    AND public.current_company_id() = company_id
  );

CREATE POLICY "staff_penalties_update"
  ON public.staff_penalties FOR UPDATE TO authenticated
  USING (public.is_super_admin() OR public.has_permission('payroll.manage'))
  WITH CHECK (public.is_super_admin() OR public.has_permission('payroll.manage'));

CREATE POLICY "staff_penalties_delete"
  ON public.staff_penalties FOR DELETE TO authenticated
  USING (public.is_super_admin() AND NOT is_settled);