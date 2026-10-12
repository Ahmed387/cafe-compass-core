import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { KeyRound } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { useAuth, type PartnerTier } from "@/lib/auth";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { HUBS } from "@/modules/shell/hubs";

type Mode = "fixed" | "percent" | "hybrid";

/**
 * One window per user for governance: Super Admin grant (root only),
 * managerial pay (root only), partner tier and menu visibility overrides.
 * Every write goes through a database action that re-checks the caller.
 */
export function UserAccessDialog({
  profileId,
  name,
  isSuper,
  isRootTarget,
}: {
  profileId: string;
  name: string;
  isSuper: boolean;
  isRootTarget: boolean;
}) {
  const { me } = useAuth();
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const isRoot = me?.isRoot ?? false;

  const details = useQuery({
    queryKey: ["user-access", profileId],
    enabled: open,
    queryFn: async () => {
      const [ov, comp, partner] = await Promise.all([
        supabase.from("user_nav_overrides").select("path, visible").eq("profile_id", profileId),
        supabase.from("manager_compensation").select("mode, fixed_amount, percent, basis").eq("profile_id", profileId).maybeSingle(),
        supabase.from("partners").select("id, tier").eq("user_id", profileId).eq("status", "active").maybeSingle(),
      ]);
      return {
        overrides: Object.fromEntries((ov.data ?? []).map((o) => [o.path, o.visible])) as Record<string, boolean>,
        comp: comp.data,
        partner: partner.data,
      };
    },
  });

  const [comp, setComp] = useState({ mode: "fixed" as Mode, fixed: "0", percent: "0", basis: "profit" });
  useEffect(() => {
    const c = details.data?.comp;
    if (c) setComp({ mode: c.mode as Mode, fixed: String(c.fixed_amount), percent: String(c.percent), basis: c.basis });
  }, [details.data?.comp]);

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["user-access", profileId] });
    qc.invalidateQueries({ queryKey: ["me"] });
    qc.invalidateQueries({ queryKey: ["users"] });
  };
  const onError = (e: unknown) => toast.error(friendlyError(e, lang));
  const saved = () => toast.success(ar ? "تم الحفظ." : "Saved.");

  const superMut = useMutation({
    mutationFn: async (on: boolean) => {
      const { error } = await supabase.rpc("set_user_super_admin", { _profile_id: profileId, _on: on });
      if (error) throw error;
    },
    onSuccess: () => { refresh(); saved(); },
    onError,
  });
  const navMut = useMutation({
    mutationFn: async (input: { path: string; visible: boolean | null }) => {
      const { error } = await supabase.rpc("set_nav_override", {
        _profile_id: profileId,
        _path: input.path,
        _visible: input.visible as boolean,
      });
      if (error) throw error;
    },
    onSuccess: refresh,
    onError,
  });
  const tierMut = useMutation({
    mutationFn: async (tier: PartnerTier) => {
      const { error } = await supabase.rpc("set_partner_tier", { _partner_id: details.data!.partner!.id, _tier: tier });
      if (error) throw error;
    },
    onSuccess: () => { refresh(); saved(); },
    onError,
  });
  const compMut = useMutation({
    mutationFn: async () => {
      const fixed = Number(comp.fixed);
      const percent = Number(comp.percent);
      if (!(fixed >= 0) || !(percent >= 0 && percent <= 100)) throw new Error(ar ? "قيم غير صحيحة" : "Invalid values");
      const { error } = await supabase.rpc("set_manager_compensation", {
        _profile_id: profileId, _mode: comp.mode, _fixed: fixed, _percent: percent, _basis: comp.basis,
      });
      if (error) throw error;
    },
    onSuccess: () => { refresh(); saved(); },
    onError,
  });

  const overrides = details.data?.overrides ?? {};
  const NavState = ({ path }: { path: string }) => {
    const value = overrides[path];
    const opts: Array<{ v: boolean | null; label: string }> = [
      { v: null, label: ar ? "تلقائي" : "Auto" },
      { v: true, label: ar ? "إظهار" : "Show" },
      { v: false, label: ar ? "إخفاء" : "Hide" },
    ];
    return (
      <div className="flex gap-1">
        {opts.map((o) => (
          <Button
            key={String(o.v)}
            size="sm"
            type="button"
            variant={(value ?? null) === o.v ? "default" : "outline"}
            className="h-7 px-2 text-xs"
            disabled={navMut.isPending}
            onClick={() => navMut.mutate({ path, visible: o.v })}
          >
            {o.label}
          </Button>
        ))}
      </div>
    );
  };

  const tiers: Array<{ v: PartnerTier; label: string }> = [
    { v: "silent", label: ar ? "شريك مستثمر (عرض فقط)" : "Silent investor" },
    { v: "manager", label: ar ? "شريك ومدير" : "Partner & manager" },
    { v: "manager_employee", label: ar ? "شريك ومدير وموظف" : "Partner, manager & employee" },
  ];

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm" variant="outline" aria-label={ar ? "الصلاحيات والقوائم" : "Access & menus"}>
          <KeyRound className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{(ar ? "الصلاحيات والقوائم — " : "Access & menus — ") + name}</DialogTitle>
        </DialogHeader>

        <section className="space-y-2 rounded-md border p-3">
          <div className="flex items-center justify-between gap-3">
            <div>
              <p className="text-sm font-semibold">{ar ? "سوبر أدمن" : "Super Admin"}</p>
              <p className="text-xs text-muted-foreground">
                {isRootTarget
                  ? ar ? "المالك الأساسي — دائم ولا يمكن تغييره." : "Root owner — permanent, cannot be changed."
                  : ar ? "المنح والسحب للمالك الأساسي فقط." : "Only the root owner can grant or revoke."}
              </p>
            </div>
            <Switch
              checked={isSuper || isRootTarget}
              disabled={!isRoot || isRootTarget || superMut.isPending}
              onCheckedChange={(on) => superMut.mutate(on)}
            />
          </div>
        </section>

        {details.data?.partner && (
          <section className="space-y-2 rounded-md border p-3">
            <p className="text-sm font-semibold">{ar ? "مستوى الشريك" : "Partner level"}</p>
            <div className="flex flex-wrap gap-2">
              {tiers.map((tier) => (
                <Button
                  key={tier.v}
                  size="sm"
                  variant={details.data?.partner?.tier === tier.v ? "default" : "outline"}
                  disabled={tierMut.isPending}
                  onClick={() => tierMut.mutate(tier.v)}
                >
                  {tier.label}
                </Button>
              ))}
            </div>
          </section>
        )}

        {isRoot && (
          <section className="space-y-3 rounded-md border p-3">
            <p className="text-sm font-semibold">{ar ? "تعويض الإدارة" : "Managerial pay"}</p>
            <div className="flex flex-wrap gap-2">
              {(["fixed", "percent", "hybrid"] as Mode[]).map((m) => (
                <Button key={m} size="sm" variant={comp.mode === m ? "default" : "outline"} onClick={() => setComp({ ...comp, mode: m })}>
                  {m === "fixed" ? (ar ? "راتب ثابت" : "Fixed") : m === "percent" ? (ar ? "نسبة" : "Percent") : ar ? "ثابت + نسبة" : "Hybrid"}
                </Button>
              ))}
            </div>
            <div className="grid gap-3 sm:grid-cols-3">
              {comp.mode !== "percent" && (
                <div className="space-y-1">
                  <Label>{ar ? "المبلغ الشهري" : "Monthly amount"}</Label>
                  <Input type="number" min={0} value={comp.fixed} onChange={(e) => setComp({ ...comp, fixed: e.target.value })} />
                </div>
              )}
              {comp.mode !== "fixed" && (
                <>
                  <div className="space-y-1">
                    <Label>{ar ? "النسبة %" : "Percent %"}</Label>
                    <Input type="number" min={0} max={100} value={comp.percent} onChange={(e) => setComp({ ...comp, percent: e.target.value })} />
                  </div>
                  <div className="space-y-1">
                    <Label>{ar ? "من" : "Of"}</Label>
                    <div className="flex gap-1">
                      {(["profit", "sales"] as const).map((b) => (
                        <Button key={b} size="sm" variant={comp.basis === b ? "default" : "outline"} onClick={() => setComp({ ...comp, basis: b })}>
                          {b === "profit" ? (ar ? "صافي الربح" : "Net profit") : ar ? "المبيعات" : "Sales"}
                        </Button>
                      ))}
                    </div>
                  </div>
                </>
              )}
            </div>
            <Button size="sm" onClick={() => compMut.mutate()} disabled={compMut.isPending}>
              {t("common.save")}
            </Button>
          </section>
        )}

        <section className="space-y-2 rounded-md border p-3">
          <p className="text-sm font-semibold">{ar ? "ظهور الأقسام والتبويبات" : "Section & tab visibility"}</p>
          {HUBS.map((hub) => (
            <div key={hub.id} className="space-y-1 border-t pt-2 first:border-t-0 first:pt-0">
              <div className="flex items-center justify-between gap-2">
                <span className="text-sm font-medium">{t(hub.labelKey)}</span>
                <NavState path={hub.path} />
              </div>
              {hub.tabs.filter((tab) => tab.to !== hub.path).map((tab) => (
                <div key={tab.to} className="flex items-center justify-between gap-2 ps-4">
                  <span className="text-xs text-muted-foreground">{t(tab.labelKey)}</span>
                  <NavState path={tab.to} />
                </div>
              ))}
            </div>
          ))}
        </section>
      </DialogContent>
    </Dialog>
  );
}
