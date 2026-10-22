import { useQuery } from "@tanstack/react-query";

import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";

/**
 * Refunds, line removals and cancellations only while the invoice's own shift
 * is open (server rule _assert_order_shift_open). Cashiers may return orders of
 * their own open shift without a manager (server rule can_refund_order).
 */
export function useOrderShiftAccess(shiftId: string | null | undefined) {
  const { can, me } = useAuth();
  const orderShift = useQuery({
    queryKey: ["order-shift-open", shiftId, me?.profile.id],
    enabled: Boolean(shiftId && me?.profile.id),
    queryFn: async () => {
      const { data: shift, error } = await supabase
        .from("shifts")
        .select("id, user_id, status")
        .eq("id", shiftId!)
        .maybeSingle();
      if (error) throw error;
      if (!shift || shift.status !== "open") return { open: false, mine: false };
      if (shift.user_id === me!.profile.id) return { open: true, mine: true };
      const { data: crew } = await supabase
        .from("shift_staff")
        .select("staff_id")
        .eq("shift_id", shift.id)
        .eq("staff_id", me!.profile.id);
      return { open: true, mine: (crew ?? []).length > 0 };
    },
  });
  const shiftClosed = orderShift.data?.open === false;
  const canRefund =
    orderShift.data?.open === true &&
    (can("pos.process_refund") || (can("pos.create_order") && orderShift.data.mine));
  return { shiftClosed, canRefund };
}
