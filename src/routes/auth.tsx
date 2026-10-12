import { createFileRoute, Link, useRouter } from "@tanstack/react-router";
import { Coffee, Eye, EyeOff } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Checkbox } from "@/components/ui/checkbox";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/auth")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Sign in — 20s Coffee" },
      {
        name: "description",
        content: "Secure sign in for coffee shop staff, managers, accountants and partners.",
      },
      { property: "og:title", content: "Sign in — 20s Coffee" },
      { property: "og:description", content: "Secure sign in for your coffee shop team." },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const { t, lang, setLang } = useI18n();
  const { session, sessionLoaded, me, meLoading } = useAuth();
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [remember, setRemember] = useState(true);
  const [mode, setMode] = useState<"signin" | "forgot">("signin");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!sessionLoaded || !session || meLoading || !me) return;
    if (me.profile.is_active) router.navigate({ to: "/dashboard", replace: true });
  }, [session, sessionLoaded, me, meLoading, router]);

  useEffect(() => {
    if (window.sessionStorage.getItem("csm.disabled-account") !== "1") return;
    window.sessionStorage.removeItem("csm.disabled-account");
    toast.error(lang === "ar" ? "هذا الحساب غير نشط. راجع مدير النظام." : "This account is inactive. Contact an administrator.");
  }, [lang]);

  async function handleSignIn(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    try {
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) throw error;
      const { data: authData } = await supabase.auth.getUser();
      const authUserId = authData.user?.id;
      if (!authUserId) throw new Error("Unable to verify this account");
      const { data: profile, error: profileError } = await supabase
        .from("user_profiles")
        .select("is_active")
        .eq("auth_user_id", authUserId)
        .maybeSingle();
      if (profileError) throw profileError;
      if (!profile?.is_active) {
        await supabase.auth.signOut();
        throw new Error(lang === "ar" ? "هذا الحساب غير نشط. راجع مدير النظام." : "This account is inactive. Contact an administrator.");
      }
      if (!remember) window.sessionStorage.setItem("csm.ephemeral", "1");
      await supabase.rpc("bootstrap_current_user", {});
      await supabase.rpc("log_audit", { _action: "auth.login", _module: "auth" });
      router.navigate({ to: "/dashboard", replace: true });
    } catch (error) {
      toast.error(friendlyError(error, lang));
    } finally {
      setBusy(false);
    }
  }

  async function handleForgot(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    try {
      await supabase.auth.resetPasswordForEmail(email, {
        redirectTo: `${window.location.origin}/reset-password`,
      });
      toast.success(t("auth.reset.sent"));
      setMode("signin");
    } catch (error) {
      toast.error(friendlyError(error, lang));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary px-4 py-10">
      <div className="w-full max-w-md">
        <div className="mb-6 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <span className="flex size-10 items-center justify-center rounded-lg bg-primary text-primary-foreground">
              <Coffee className="size-5" />
            </span>
            <div>
              <p className="text-lg font-bold text-foreground">{t("app.name")}</p>
              <p className="text-xs text-muted-foreground">{t("app.tagline")}</p>
            </div>
          </div>
          <Button variant="outline" size="sm" onClick={() => setLang(lang === "en" ? "ar" : "en")}>
            {lang === "en" ? "العربية" : "English"}
          </Button>
        </div>

        <div className="rounded-xl border border-border bg-card p-6 shadow-sm">
          {mode === "signin" ? (
            <form className="space-y-4" onSubmit={handleSignIn}>
              <h1 className="text-xl font-semibold text-card-foreground">{t("auth.signin")}</h1>
              <div className="space-y-2">
                <Label htmlFor="email">{t("auth.email")}</Label>
                <Input
                  id="email"
                  type="email"
                  autoComplete="email"
                  required
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="password">{t("auth.password")}</Label>
                <div className="relative">
                  <Input
                    id="password"
                    type={showPassword ? "text" : "password"}
                    autoComplete="current-password"
                    required
                    className="pe-11"
                    value={password}
                    onChange={(event) => setPassword(event.target.value)}
                  />
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className="absolute end-1 top-1/2 size-8 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                    aria-label={
                      showPassword
                        ? lang === "ar"
                          ? "إخفاء كلمة المرور"
                          : "Hide password"
                        : lang === "ar"
                          ? "إظهار كلمة المرور"
                          : "Show password"
                    }
                    title={
                      showPassword
                        ? lang === "ar"
                          ? "إخفاء كلمة المرور"
                          : "Hide password"
                        : lang === "ar"
                          ? "إظهار كلمة المرور"
                          : "Show password"
                    }
                    onClick={() => setShowPassword((visible) => !visible)}
                  >
                    {showPassword ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                  </Button>
                </div>
              </div>
              <div className="flex items-center justify-between gap-2">
                <label className="flex items-center gap-2 text-sm text-muted-foreground">
                  <Checkbox
                    checked={remember}
                    onCheckedChange={(value) => setRemember(value === true)}
                  />
                  {t("auth.remember")}
                </label>
                <button
                  type="button"
                  className="text-sm font-medium text-primary underline"
                  onClick={() => setMode("forgot")}
                >
                  {t("auth.forgot")}
                </button>
              </div>
              <Button type="submit" className="h-11 w-full" disabled={busy}>
                {busy ? t("common.loading") : t("auth.signin")}
              </Button>
            </form>
          ) : (
            <form className="space-y-4" onSubmit={handleForgot}>
              <h1 className="text-xl font-semibold text-card-foreground">
                {t("auth.reset.title")}
              </h1>
              <div className="space-y-2">
                <Label htmlFor="reset-email">{t("auth.email")}</Label>
                <Input
                  id="reset-email"
                  type="email"
                  required
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                />
              </div>
              <Button type="submit" className="h-11 w-full" disabled={busy}>
                {t("auth.reset.send")}
              </Button>
              <Button
                type="button"
                variant="ghost"
                className="w-full"
                onClick={() => setMode("signin")}
              >
                {t("auth.back")}
              </Button>
            </form>
          )}
        </div>

        <p className="mt-4 text-center text-xs text-muted-foreground">
          <Link to="/">{t("app.name")}</Link>
        </p>
      </div>
    </div>
  );
}
