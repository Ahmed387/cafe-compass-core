import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { createPartnerLogin } from "@/lib/partner-account.functions";

/** Super Admin tool to link an existing login or create a new one for a partner. */
export function PartnerAccountLink({ partnerId, partnerName }: { partnerId: string; partnerName: string }) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const createLogin = useServerFn(createPartnerLogin);
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState<"existing" | "new">("existing");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const run = useMutation({
    mutationFn: async () => {
      if (mode === "existing") {
        const { error } = await supabase.rpc("link_partner_account", { _partner_id: partnerId, _email: email.trim() });
        if (error) throw error;
      } else {
        await createLogin({ data: { partner_id: partnerId, email: email.trim(), password, name: partnerName } });
      }
    },
    onSuccess: () => {
      toast.success(ar ? "تم ربط الحساب" : "Account linked");
      setOpen(false);
      qc.invalidateQueries();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  if (!open) {
    return (
      <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
        🔗 {ar ? "ربط / دعوة حساب مستخدم" : "Link / invite user account"}
      </Button>
    );
  }
  return (
    <div className="grid gap-2 rounded-md border border-dashed border-border p-3">
      <div className="flex gap-2">
        <Button size="sm" variant={mode === "existing" ? "default" : "outline"} onClick={() => setMode("existing")}>
          {ar ? "حساب موجود" : "Existing account"}
        </Button>
        <Button size="sm" variant={mode === "new" ? "default" : "outline"} onClick={() => setMode("new")}>
          {ar ? "إنشاء حساب جديد" : "Create new login"}
        </Button>
      </div>
      <div className="space-y-1">
        <Label className="text-xs">{ar ? "البريد الإلكتروني" : "Email"}</Label>
        <Input type="email" dir="ltr" value={email} maxLength={255} onChange={(e) => setEmail(e.target.value)} />
      </div>
      {mode === "new" && (
        <div className="space-y-1">
          <Label className="text-xs">{ar ? "كلمة المرور (8 أحرف على الأقل)" : "Password (min 8 characters)"}</Label>
          <Input type="password" dir="ltr" value={password} maxLength={72} onChange={(e) => setPassword(e.target.value)} />
        </div>
      )}
      <div className="flex gap-2">
        <Button size="sm" disabled={run.isPending || !email.trim() || (mode === "new" && password.length < 8)} onClick={() => run.mutate()}>
          {ar ? "ربط الحساب" : "Link account"}
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setOpen(false)}>{ar ? "إلغاء" : "Cancel"}</Button>
      </div>
    </div>
  );
}
