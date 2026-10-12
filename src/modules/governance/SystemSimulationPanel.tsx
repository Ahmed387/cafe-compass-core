import { useMutation, useQuery } from "@tanstack/react-query";
import { Power } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";

const rpc = supabase.rpc as unknown as (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: Error | null }>;

/** Super Admin: go-live wipe of operations history. */
export function SystemSimulationPanel() {
  const isSuper = useQuery({
    queryKey: ["is-super-admin"],
    queryFn: async () => Boolean((await supabase.rpc("is_super_admin")).data),
  });
  const [confirm, setConfirm] = useState("");
  const [reason, setReason] = useState("");
  const [resetStock, setResetStock] = useState(false);

  const reset = useMutation({
    mutationFn: async () => {
      const { error } = await rpc("go_live_reset", { _confirm: confirm, _reason: reason, _reset_stock: resetStock });
      if (error) throw error;
    },
    onSuccess: () => { toast.success("تمت تهيئة النظام للتشغيل الفعلي"); setConfirm(""); setReason(""); },
    onError: (e) => toast.error(friendlyError(e)),
  });

  if (!isSuper.data) return null;
  return (
    <div className="grid gap-4 lg:max-w-xl">
      <Card className="rounded-2xl shadow-sm">
        <CardHeader><CardTitle className="flex items-center gap-2 text-base"><Power className="size-4" />تهيئة التشغيل الفعلي (Go-Live)</CardTitle></CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-muted-foreground">يمسح الورديات والطلبات وحركات المخزون والمصروفات والرواتب والحضور والتوزيعات وصندوق التطوير وقيود الشركاء والسجل. يحتفظ بالإعدادات والمنيو والوصفات والأصناف والأدوار والحسابات والشركاء. لا يمكن التراجع.</p>
          <div className="space-y-1"><Label>السبب</Label><Input value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          <div className="space-y-1"><Label>اكتب RESET للتأكيد</Label><Input dir="ltr" value={confirm} onChange={(e) => setConfirm(e.target.value)} /></div>
          <label className="flex items-center gap-2 text-sm"><Switch checked={resetStock} onCheckedChange={setResetStock} />تصفير كميات المخزون أيضًا</label>
          <Button variant="destructive" disabled={confirm !== "RESET" || reason.trim().length < 3 || reset.isPending} onClick={() => reset.mutate()}>تنفيذ التهيئة</Button>
        </CardContent>
      </Card>
    </div>
  );
}
