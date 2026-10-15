import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { BackupsPanel } from "@/modules/governance/BackupsPanel";
import { DangerZonePanel } from "@/modules/governance/DangerZonePanel";
import { TestShiftResetPanel } from "@/modules/governance/TestShiftResetPanel";
import { SystemSimulationPanel } from "@/modules/governance/SystemSimulationPanel";
import { PaymentMethodsCard } from "@/modules/governance/PaymentMethodsCard";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/settings")({
  head: () => ({
    meta: [
      { title: "Settings — 20s Coffee" },
      { name: "description", content: "Company identity, currency, timezone and language." },
      { property: "og:title", content: "Settings — 20s Coffee" },
      { property: "og:description", content: "Configure company, currency and language." },
    ],
  }),
  component: SettingsPage,
});

function SettingsPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const queryClient = useQueryClient();
  const [form, setForm] = useState({
    name: "",
    legal_name: "",
    currency: "EGP",
    timezone: "Africa/Cairo",
    default_language: "en" as "ar" | "en",
  });

  useEffect(() => {
    if (!me?.company) return;
    setForm({
      name: me.company.name,
      legal_name: me.company.legal_name ?? "",
      currency: me.company.currency,
      timezone: me.company.timezone,
      default_language: me.company.default_language,
    });
  }, [me?.company]);

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase
        .from("companies")
        .update({
          name: form.name,
          legal_name: form.legal_name || null,
          currency: form.currency,
          timezone: form.timezone,
          default_language: form.default_language,
          tax_enabled: false,
          tax_rate: 0,
        })
        .eq("id", me!.profile.company_id);
      if (error) throw error;
      await supabase.rpc("log_audit", {
        _action: "settings.update",
        _module: "settings",
        _entity_type: "companies",
        _entity_id: me!.profile.company_id,
        _new_values: form,
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["me"] });
      toast.success(lang === "ar" ? "تم حفظ الإعدادات." : "Settings saved.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!can("settings.view")) return <NoPermission message={t("common.noAccess")} />;
  const readOnly = !can("settings.manage");

  return (
    <div className="mx-auto w-full max-w-2xl">
      <PageHeader title={t("settings.title")} />
      <h2 className="mb-2 text-sm font-semibold text-muted-foreground">{lang === "ar" ? "١. بيانات النشاط ورسالة الإيصال" : "1. Business profile & receipt message"}</h2>
      <Card className="mb-4">
        <CardHeader>
          <CardTitle className="text-base">{t("settings.company")}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>{t("common.name")}</Label>
            <Input
              value={form.name}
              disabled={readOnly}
              onChange={(event) => setForm({ ...form, name: event.target.value })}
            />
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label>{t("settings.currency")}</Label>
              <Input
                value={form.currency}
                disabled={readOnly}
                onChange={(event) => setForm({ ...form, currency: event.target.value })}
              />
            </div>
            <div className="space-y-2">
              <Label>{t("settings.timezone")}</Label>
              <Input
                value={form.timezone}
                disabled={readOnly}
                onChange={(event) => setForm({ ...form, timezone: event.target.value })}
              />
            </div>
          </div>
          <div className="space-y-2">
            <Label>{t("settings.language")}</Label>
            <Select
              value={form.default_language}
              onValueChange={(value) =>
                setForm({ ...form, default_language: value as "ar" | "en" })
              }
              disabled={readOnly}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="en">English</SelectItem>
                <SelectItem value="ar">العربية</SelectItem>
              </SelectContent>
            </Select>
          </div>
          {!readOnly && (
            <Button onClick={() => save.mutate()} disabled={save.isPending}>
              {t("common.save")}
            </Button>
          )}
        </CardContent>
      </Card>

      {me?.roleNames.includes("Super Admin") && <ReceiptFooterCard />}
      <h2 className="mb-2 mt-8 text-sm font-semibold text-muted-foreground">{lang === "ar" ? "٢. سياسات الورديات وساعات العمل" : "2. Shift policies & working hours"}</h2>
      <ScheduleCard readOnly={readOnly} />
      <ShiftPolicyCard readOnly={readOnly} />
      <h2 className="mb-2 mt-8 text-sm font-semibold text-muted-foreground">{lang === "ar" ? "٣. المالية والنسخ الاحتياطي" : "3. Finance & backups"}</h2>
      <PaymentMethodsCard readOnly={readOnly} />
      <ReserveCard readOnly={readOnly} />
      <BackupsPanel />
      <TestShiftResetPanel />
      <SystemSimulationPanel />
      <DangerZonePanel />
    </div>
  );
}

function ReserveCard({ readOnly }: { readOnly: boolean }) {
  const { lang } = useI18n();
  const { me } = useAuth();
  const ar = lang === "ar";
  const queryClient = useQueryClient();
  const [form, setForm] = useState({ type: "percent", value: "0" });

  const { data: row } = useQuery({
    queryKey: ["finance-settings"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("app_settings")
        .select("id, value")
        .eq("key", "finance")
        .maybeSingle();
      if (error) throw error;
      return data;
    },
  });

  useEffect(() => {
    const value = (row?.value ?? {}) as Record<string, unknown>;
    setForm({
      type: String(value["operating_reserve_type"] ?? "percent"),
      value: String(value["operating_reserve_value"] ?? 0),
    });
  }, [row]);

  const save = useMutation({
    mutationFn: async () => {
      const value = {
        ...((row?.value ?? {}) as Record<string, unknown>),
        operating_reserve_type: form.type,
        operating_reserve_value: Number(form.value) || 0,
      };
      if (row?.id) {
        const { error } = await supabase.from("app_settings").update({ value }).eq("id", row.id);
        if (error) throw error;
      } else {
        const { error } = await supabase
          .from("app_settings")
          .insert({ company_id: me!.profile.company_id, key: "finance", value });
        if (error) throw error;
      }
      await supabase.rpc("log_audit", {
        _action: "settings.operating_reserve",
        _module: "settings",
        _entity_type: "app_settings",
        _new_values: value as never,
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["finance-settings"] });
      toast.success(ar ? "تم حفظ الاحتياطي التشغيلي." : "Operating reserve saved.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Card className="mt-4">
      <CardHeader>
        <CardTitle className="text-base">
          {ar ? "الاحتياطي التشغيلي" : "Operating reserve"}
        </CardTitle>
        <p className="text-sm text-muted-foreground">
          {ar
            ? "المبلغ أو النسبة اللي بتتخصم من صافي الربح قبل التوزيع على الشركاء."
            : "Amount or percentage kept from net profit before distributing to partners."}
        </p>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label>{ar ? "النوع" : "Type"}</Label>
            <Select
              value={form.type}
              onValueChange={(value) => setForm({ ...form, type: value })}
              disabled={readOnly}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="percent">{ar ? "نسبة %" : "Percentage %"}</SelectItem>
                <SelectItem value="amount">{ar ? "مبلغ ثابت" : "Fixed amount"}</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-2">
            <Label>{ar ? "القيمة" : "Value"}</Label>
            <Input
              type="number"
              min="0"
              step="0.01"
              value={form.value}
              disabled={readOnly}
              onChange={(event) => setForm({ ...form, value: event.target.value })}
            />
          </div>
        </div>
        {!readOnly && (
          <Button onClick={() => save.mutate()} disabled={save.isPending}>
            {ar ? "حفظ" : "Save"}
          </Button>
        )}
      </CardContent>
    </Card>
  );
}

function ScheduleCard({ readOnly }: { readOnly: boolean }) {
  const { t, lang } = useI18n();
  const queryClient = useQueryClient();

  const { data: rows } = useQuery({
    queryKey: ["work-schedules"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("work_schedules")
        .select("id, weekday, opens_at, closes_at, is_closed")
        .order("weekday");
      if (error) throw error;
      return data ?? [];
    },
  });

  const update = useMutation({
    mutationFn: async (input: {
      id: string;
      patch: { opens_at?: string; closes_at?: string; is_closed?: boolean };
    }) => {
      const { error } = await supabase
        .from("work_schedules")
        .update(input.patch)
        .eq("id", input.id);
      if (error) throw error;
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["work-schedules"] }),
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Card className="mb-4">
      <CardHeader>
        <CardTitle className="text-base">{t("settings.schedule")}</CardTitle>
        <p className="text-sm text-muted-foreground">{t("settings.scheduleHint")}</p>
      </CardHeader>
      <CardContent className="space-y-3">
        {(rows ?? []).map((row) => (
          <div
            key={row.id}
            className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-md border border-border p-3 sm:grid-cols-[7rem_1fr_1fr_auto]"
          >
            <span className="truncate text-sm font-medium">{t(`day.${row.weekday}`)}</span>
            <Input
              type="time"
              value={String(row.opens_at).slice(0, 5)}
              disabled={readOnly || row.is_closed}
              onChange={(event) =>
                update.mutate({ id: row.id, patch: { opens_at: event.target.value } })
              }
            />
            <Input
              type="time"
              value={String(row.closes_at).slice(0, 5)}
              disabled={readOnly || row.is_closed}
              onChange={(event) =>
                update.mutate({ id: row.id, patch: { closes_at: event.target.value } })
              }
            />
            <div className="flex items-center justify-between gap-3 rounded-md border border-border p-3">
              <Label className="text-sm">{t("settings.workday")}</Label>
              <Switch
                checked={!row.is_closed}
                disabled={readOnly}
                onCheckedChange={(value) =>
                  update.mutate({ id: row.id, patch: { is_closed: !value } })
                }
              />
            </div>
          </div>
        ))}
      </CardContent>
    </Card>
  );
}

function ShiftPolicyCard({ readOnly }: { readOnly: boolean }) {
  const { t, lang } = useI18n();
  const queryClient = useQueryClient();
  const [form, setForm] = useState({ warn: "30", grace: "5", auto: true });

  const { data: policy } = useQuery({
    queryKey: ["shift-policy"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shift_policies")
        .select("id, warn_minutes, open_grace_minutes, auto_close")
        .maybeSingle();
      if (error) throw error;
      return data;
    },
  });

  useEffect(() => {
    if (!policy) return;
    setForm({
      warn: String(policy.warn_minutes),
      grace: String(policy.open_grace_minutes),
      auto: policy.auto_close,
    });
  }, [policy]);

  const save = useMutation({
    mutationFn: async () => {
      if (!policy) return;
      const { error } = await supabase
        .from("shift_policies")
        .update({
          warn_minutes: Number(form.warn),
          open_grace_minutes: Number(form.grace),
          auto_close: form.auto,
        })
        .eq("id", policy.id);
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["shift-policy"] });
      toast.success(lang === "ar" ? "تم حفظ الإعدادات." : "Settings saved.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{t("settings.shiftPolicy")}</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label>{t("settings.warnMinutes")}</Label>
            <Input
              type="number"
              min="5"
              value={form.warn}
              disabled={readOnly}
              onChange={(event) => setForm({ ...form, warn: event.target.value })}
            />
          </div>
          <div className="space-y-2">
            <Label>{t("settings.graceMinutes")}</Label>
            <Input
              type="number"
              min="0"
              value={form.grace}
              disabled={readOnly}
              onChange={(event) => setForm({ ...form, grace: event.target.value })}
            />
          </div>
        </div>
        <div className="flex items-center justify-between rounded-md border border-border p-3">
          <Label>{t("settings.autoClose")}</Label>
          <Switch
            checked={form.auto}
            disabled={readOnly}
            onCheckedChange={(value) => setForm({ ...form, auto: value })}
          />
        </div>
        {!readOnly && (
          <Button onClick={() => save.mutate()} disabled={save.isPending || !policy}>
            {t("common.save")}
          </Button>
        )}
      </CardContent>
    </Card>
  );
}

// ===== Receipt footer message (super admin) =====
type FooterValue = { message?: string } | string;

function ReceiptFooterCard() {
  const { t, lang } = useI18n();
  const { me } = useAuth();
  const ar = lang === "ar";
  const queryClient = useQueryClient();
  const [draft, setDraft] = useState<string | null>(null);

  const { data: row, isLoading } = useQuery({
    queryKey: ["settings-receipt-footer"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("app_settings")
        .select("id, value")
        .eq("key", "receipt_footer_message")
        .maybeSingle();
      if (error) throw error;
      return data;
    },
  });

  const value = (row?.value ?? "") as FooterValue;
  const message = typeof value === "string" ? value : (value.message ?? "");
  const current = draft ?? message;

  const save = useMutation({
    mutationFn: async () => {
      if (row?.id) {
        const { error } = await supabase
          .from("app_settings")
          .update({ value: { message: current.trim() } })
          .eq("id", row.id);
        if (error) throw error;
      } else {
        const { error } = await supabase.from("app_settings").insert({
          company_id: me!.profile.company_id,
          scope: "company",
          key: "receipt_footer_message",
          value: { message: current.trim() },
        });
        if (error) throw error;
      }
      await supabase.rpc("log_audit", {
        _action: "settings.receipt_footer",
        _module: "settings",
        _entity_type: "app_settings",
        _new_values: { message: current.trim() } as never,
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["settings-receipt-footer"] });
      queryClient.invalidateQueries({ queryKey: ["receipt-footer-settings"] });
      toast.success(ar ? "تم حفظ رسالة الفاتورة." : "Receipt message saved.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Card className="mb-4">
      <CardHeader>
        <CardTitle className="text-base">{t("settings.receiptFooter")}</CardTitle>
        <p className="text-sm text-muted-foreground">{t("settings.receiptFooterHint")}</p>
      </CardHeader>
      <CardContent className="space-y-4">
        <Input
          value={current}
          disabled={isLoading}
          onChange={(event) => setDraft(event.target.value)}
        />
        <Button
          onClick={() => save.mutate()}
          disabled={save.isPending || current.trim() === message.trim()}
        >
          {t("common.save")}
        </Button>
      </CardContent>
    </Card>
  );
}
