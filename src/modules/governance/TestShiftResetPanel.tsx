import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Eraser } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";

type ShiftRow = {
  id: string;
  opened_at: string;
  closing_cash: number | null;
  variance: number | null;
};

/** Super-admin: remove a single closed test shift (orders, payments, expenses) with an audit reason. */
export function TestShiftResetPanel() {
  const qc = useQueryClient();
  const [reason, setReason] = useState("");
  const isSuper = useQuery({
    queryKey: ["is-super-admin"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("is_super_admin");
      if (error) throw error;
      return Boolean(data);
    },
  });
  const shifts = useQuery({
    queryKey: ["test-shift-candidates"],
    enabled: isSuper.data === true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select("id, opened_at, closing_cash, variance")
        .eq("status", "closed")
        .order("opened_at", { ascending: false })
        .limit(30);
      if (error) throw error;
      return (data ?? []) as ShiftRow[];
    },
  });
  const reset = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc("reset_test_shift" as never, {
        _shift_id: id,
        _reason: reason,
      } as never);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("تم حذف الوردية التجريبية وتسجيل العملية في سجل التدقيق");
      qc.invalidateQueries();
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  if (isSuper.data !== true) return null;

  return (
    <Card className="rounded-2xl shadow-sm">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <Eraser className="size-4 text-destructive" />
          حذف ورديات تجريبية
        </CardTitle>
        <p className="text-sm text-muted-foreground">
          يحذف الوردية مع طلباتها ومدفوعاتها ومصروفاتها نهائيًا. حركات المخزون لا تُعكس.
        </p>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input
          placeholder="سبب الحذف (إلزامي)"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
        />
        <div className="divide-y rounded-xl border">
          {(shifts.data ?? []).map((s) => {
            const v = Number(s.variance ?? 0);
            return (
              <div key={s.id} className="flex items-center justify-between gap-3 p-3 text-sm">
                <div className="min-w-0">
                  <div className="truncate font-medium">
                    {new Date(s.opened_at).toLocaleString("ar-EG")}
                  </div>
                  <div className="text-xs text-muted-foreground">
                    نقدية معدودة: {Number(s.closing_cash ?? 0).toLocaleString("ar-EG")}
                  </div>
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  {v !== 0 && (
                    <Badge variant={v < 0 ? "destructive" : "success"}>
                      {v.toLocaleString("ar-EG")}
                    </Badge>
                  )}
                  <Button
                    size="sm"
                    variant="destructive"
                    disabled={reason.trim().length < 3 || reset.isPending}
                    onClick={() => {
                      if (confirm("تأكيد الحذف النهائي لهذه الوردية؟")) reset.mutate(s.id);
                    }}
                  >
                    حذف
                  </Button>
                </div>
              </div>
            );
          })}
        </div>
      </CardContent>
    </Card>
  );
}
