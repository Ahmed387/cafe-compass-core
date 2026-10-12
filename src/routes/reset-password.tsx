import { createFileRoute, useRouter } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/reset-password")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Set a new password — 20s Coffee" },
      { name: "description", content: "Choose a new password for your coffee shop account." },
      { property: "og:title", content: "Set a new password" },
      { property: "og:description", content: "Choose a new password for your account." },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: ResetPassword,
});

function ResetPassword() {
  const { t, lang } = useI18n();
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    try {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
      await supabase.rpc("log_audit", { _action: "auth.password_reset", _module: "auth" });
      toast.success(lang === "ar" ? "تم تحديث كلمة المرور." : "Password updated.");
      router.navigate({ to: "/dashboard", replace: true });
    } catch (error) {
      toast.error(friendlyError(error, lang));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary px-4">
      <form
        onSubmit={handleSubmit}
        className="w-full max-w-md space-y-4 rounded-xl border border-border bg-card p-6 shadow-sm"
      >
        <h1 className="text-xl font-semibold text-card-foreground">{t("auth.reset.title")}</h1>
        <div className="space-y-2">
          <Label htmlFor="new-password">{t("auth.newPassword")}</Label>
          <Input
            id="new-password"
            type="password"
            minLength={8}
            required
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />
        </div>
        <Button type="submit" className="h-11 w-full" disabled={busy}>
          {t("auth.updatePassword")}
        </Button>
      </form>
    </div>
  );
}
