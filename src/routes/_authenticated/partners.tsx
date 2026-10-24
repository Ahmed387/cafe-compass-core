import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  PartnerStatementDialog,
  type PartnerRow,
} from "@/components/partners/PartnerStatementDialog";
import { SuperAdminManagingCard } from "@/components/partners/SuperAdminManagingCard";
import { ContributionDialog } from "@/components/partners/ContributionDialog";
import { PartnerDashboard } from "@/components/partners/PartnerDashboard";
import { businessToday } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, formatPercent, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { CollapsibleSection, KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import { useUnpaidProfit } from "@/modules/finance/finance-queries";
import {
  AlertTriangle,
  CirclePlus,
  FileText,
  Landmark,
  PauseCircle,
  Pencil,
  PieChart,
  PlayCircle,
  RefreshCcw,
  Trash2,
  Users,
  Wallet,
} from "lucide-react";
import { PartnerMoneyFlowCards } from "@/components/partners/PartnerMoneyFlowCards";
import { matches, SmartFilterBar } from "@/modules/shell/SmartFilterBar";
import {
  PartnerLiquidationDialog,
  type LiquidationPartner,
} from "@/modules/governance/PartnerLiquidationDialog";

export const Route = createFileRoute("/_authenticated/partners")({
  head: () => ({
    meta: [
      { title: "Partners — 20s Coffee" },
      {
        name: "description",
        content: "Partners, capital contributions, derived ownership and ledger balances.",
      },
      { property: "og:title", content: "Partners — 20s Coffee" },
      { property: "og:description", content: "Partner capital, ownership and ledger balances." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: PartnersPage,
});

function PartnersPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  const [openPartner, setOpenPartner] = useState(false);
  const [partnerForm, setPartnerForm] = useState({ name: "", email: "", phone: "" });
  const [capitalFor, setCapitalFor] = useState<{ id: string; name: string } | null>(null);
  const [editPartner, setEditPartner] = useState<{ id: string; name: string; share: string } | null>(null);
  const [statementFor, setStatementFor] = useState<PartnerRow | null>(null);
  const [liquidationFor, setLiquidationFor] = useState<LiquidationPartner | null>(null);
  const [deleteFor, setDeleteFor] = useState<{ id: string; name: string } | null>(null);

  const { data } = useQuery({
    queryKey: ["partners"],
    enabled: can("partners.view"),
    queryFn: async () => {
      const [partners, ownership, balances, contributions] = await Promise.all([
        supabase
          .from("partners")
          .select("id, name, email, phone, status, user_id, customer_id, profit_share_percentage, dividends_paused, is_managing_staff, management_salary_type, management_salary_pct")
          .order("created_at"),
        supabase
          .from("partner_ownership")
          .select("partner_id, total_contributions, ownership_percentage, open_loans"),
        supabase.from("partner_balances").select("partner_id, balance, capital"),
        supabase
          .from("partner_capital_contributions")
          .select("id, partner_id, amount, contribution_date, reference, kind, effective_from, repaid_amount")
          .order("contribution_date", { ascending: false })
          .limit(50),
      ]);
      return {
        partners: partners.data ?? [],
        ownership: ownership.data ?? [],
        balances: balances.data ?? [],
        contributions: contributions.data ?? [],
      };
    },
  });

  const createPartner = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("create_partner_entry", {
        _name: partnerForm.name,
        ...(partnerForm.email ? { _email: partnerForm.email } : {}),
        ...(partnerForm.phone ? { _phone: partnerForm.phone } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setOpenPartner(false);
      setPartnerForm({ name: "", email: "", phone: "" });
      queryClient.invalidateQueries({ queryKey: ["partners"] });
      toast.success(lang === "ar" ? "تم إضافة الشريك." : "Partner added.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const updatePartner = useMutation({
    mutationFn: async () => {
      if (!editPartner) return;
      const share = editPartner.share.trim() === "" ? undefined : Number(editPartner.share);
      const { error } = await supabase.rpc("update_partner_details", {
        _partner_id: editPartner.id,
        _name: editPartner.name.trim(),
        ...(share === undefined ? {} : { _profit_share_percentage: share }),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setEditPartner(null);
      queryClient.invalidateQueries({ queryKey: ["partners"] });
      toast.success(lang === "ar" ? "تم تحديث بيانات الشريك." : "Partner updated.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const deletePartner = useMutation({
    mutationFn: async (partnerId: string) => {
      const { error } = await supabase.rpc("delete_partner_safe", { _partner_id: partnerId });
      if (error) throw error;
    },
    onSuccess: () => {
      setDeleteFor(null);
      queryClient.invalidateQueries({ queryKey: ["partners"] });
      toast.success(lang === "ar" ? "تم حذف الشريك نهائيًا." : "Partner deleted permanently.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const superAdmin = useQuery({
    queryKey: ["is-super-admin"],
    queryFn: async () => Boolean((await supabase.rpc("is_super_admin")).data),
  });
  const isSuper = superAdmin.data === true;
  const [view, setView] = useState<"active" | "archived">("active");
  const [q, setQ] = useState("");
  const togglePause = useMutation({
    mutationFn: async (p: { id: string; paused: boolean }) => {
      const { error } = await supabase.rpc("set_partner_dividends_paused", { _partner_id: p.id, _paused: p.paused });
      if (error) throw error;
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["partners"] }),
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  // Net profit earned since the last payout — what is waiting to be distributed.
  const unpaid = useUnpaidProfit(can("partners.view") && (can("reports.profit") || can("partners.view_profit")));
  const distributable = { data: unpaid.amount };

  // Partners without the company-wide permission only ever see their own share.
  if (!can("partners.view")) return <PartnerDashboard />;

  const allPartners = (data?.partners ?? []) as Array<NonNullable<typeof data>["partners"][number] & { dividends_paused?: boolean }>;
  const activeCount = allPartners.filter((p) => p.status === "active").length;
  // A capital contribution changes everyone's share from the 1st of the next month.
  const today = businessToday();
  const pendingShareDate = (data?.contributions ?? [])
    .filter((c) => c.kind === "capital" && c.effective_from > today)
    .map((c) => c.effective_from)
    .sort()[0];
  const partners = allPartners.filter(
    (p) => (view === "active" ? p.status === "active" : p.status !== "active") && matches(q, p.name, p.email, p.phone),
  );

  return (
    <div>
      <PageHeader
        title={t("partners.title")}
        description={t("partners.derived")}
        action={
          can("partners.manage") && (
            <Dialog open={openPartner} onOpenChange={setOpenPartner}>
              <DialogTrigger asChild>
                <Button>{t("partners.new")}</Button>
              </DialogTrigger>
              <DialogContent>
                <DialogHeader>
                  <DialogTitle>{t("partners.new")}</DialogTitle>
                </DialogHeader>
                <div className="space-y-3">
                  <div className="space-y-2">
                    <Label>{t("common.name")}</Label>
                    <Input
                      value={partnerForm.name}
                      onChange={(event) =>
                        setPartnerForm({ ...partnerForm, name: event.target.value })
                      }
                    />
                  </div>
                  <div className="space-y-2">
                    <Label>{t("auth.email")}</Label>
                    <Input
                      value={partnerForm.email}
                      onChange={(event) =>
                        setPartnerForm({ ...partnerForm, email: event.target.value })
                      }
                    />
                  </div>
                  <div className="space-y-2">
                    <Label>{t("common.phone")}</Label>
                    <Input
                      value={partnerForm.phone}
                      onChange={(event) =>
                        setPartnerForm({ ...partnerForm, phone: event.target.value })
                      }
                    />
                  </div>
                </div>
                <DialogFooter>
                  <Button onClick={() => createPartner.mutate()} disabled={!partnerForm.name}>
                    {t("common.create")}
                  </Button>
                </DialogFooter>
              </DialogContent>
            </Dialog>
          )
        }
      />
      {isSuper && <SuperAdminManagingCard />}

      <div className="space-y-4">
      <KpiGrid cols={3} title={lang === "ar" ? "نظرة عامة على الشراكة" : "Partnership overview"}>
        <KpiCard
          label={lang === "ar" ? "إجمالي رأس المال النشط" : "Active capital"}
          value={formatMoney(
            (data?.ownership ?? [])
              .filter((o) => partners.some((p) => p.id === o.partner_id && p.status === "active"))
              .reduce((s, r) => s + Number(r.total_contributions ?? 0), 0),
            currency,
            lang,
          )}
          tone="brand"
          formula={lang === "ar" ? "مجموع مساهمات رأس المال للشركاء النشطين." : "Sum of active partners' capital contributions."}
        />
        <KpiCard label={lang === "ar" ? "عدد الشركاء النشطين" : "Active partners"} value={partners.filter((p) => p.status === "active").length} hint={`${lang === "ar" ? "متوقف أرباحهم" : "Paused"}: ${partners.filter((p) => p.dividends_paused).length}`} formula={lang === "ar" ? "عدد الشركاء بحالة نشط ضمن التبويب والبحث الحالي." : "Partners with active status in the current view and search."} />
        <KpiCard
          label={lang === "ar" ? "صافي الأرباح القابلة للتوزيع" : "Distributable net profit"}
          value={distributable.data === undefined ? "—" : formatMoney(distributable.data, currency, lang)}
          hint={unpaid.sinceLastPayout ? (lang === "ar" ? `كل الأيام اللي متوزعتش، أولها ${unpaid.from}` : `All days not paid out yet, from ${unpaid.from}`) : (lang === "ar" ? `من ${unpaid.from} (مفيش توزيع لسه)` : `Since ${unpaid.from} (nothing paid out yet)`)}
          tone={(distributable.data ?? 0) < 0 ? "bad" : "good"}
          formula={lang === "ar" ? "صافي ربح كل الأيام اللي لسه متوزعتش من أول يوم شغل لحد النهارده (الشهور اللي اتوزعت مش داخلة) — من نفس قائمة الدخل." : "Net profit of every day not yet paid out, from the first business day to today (paid months excluded) — from the same P&L."}
        />
      </KpiGrid>
      {false && (
        <div className="mb-4 grid gap-3 sm:grid-cols-2">
          <div className="rounded-lg border border-border bg-card p-3">
            <p className="text-xs text-muted-foreground">{lang === "ar" ? "إجمالي تكلفة تأسيس الكافيه" : "Total startup cost"}</p>
            <p className="text-2xl font-bold tabular-nums">
              {formatMoney((data?.ownership ?? []).reduce((s, r) => s + Number(r.total_contributions ?? 0), 0), currency, lang)}
            </p>
          </div>
          <div className="rounded-lg border border-border bg-card p-3">
            <p className="text-xs text-muted-foreground">{lang === "ar" ? "مجموع نسب الشراكة" : "Total equity"}</p>
            <p className="text-2xl font-bold tabular-nums">
              {formatPercent((data?.ownership ?? []).reduce((s, r) => s + Number(r.ownership_percentage ?? 0), 0), lang)}
            </p>
          </div>
        </div>
      )}

      <CollapsibleSection
        icon={<Wallet className="size-4" />}
        title={lang === "ar" ? "التدفق المالي لكل شريك" : "Money flow per partner"}
        description={lang === "ar" ? "رأس المال، راتب الإدارة، الأرباح الموزعة، والرصيد الصافي" : "Capital, management salary, distributed profit and net balance"}
      >
        <PartnerMoneyFlowCards
          partners={allPartners.filter((p) => p.status === "active").map((p) => {
            const o = data?.ownership.find((r) => r.partner_id === p.id);
            const x = p as typeof p & { is_managing_staff?: boolean | null; management_salary_type?: string | null; management_salary_pct?: number | null };
            return {
              id: p.id, name: p.name, user_id: p.user_id ?? null,
              is_managing_staff: x.is_managing_staff ?? false,
              management_salary_type: x.management_salary_type, management_salary_pct: x.management_salary_pct,
              capital: Number(o?.total_contributions ?? 0),
              equity: Number(p.profit_share_percentage ?? o?.ownership_percentage ?? 0),
              balance: Number(data?.balances.find((r) => r.partner_id === p.id)?.balance ?? 0),
            };
          })}
          currency={currency}
          lang={lang}
          isSuper={isSuper}
          openNetProfit={distributable.data}
        />
      </CollapsibleSection>

      <CollapsibleSection
        icon={<PieChart className="size-4" />}
        title={lang === "ar" ? "الحصص ونسب توزيع الأرباح" : "Equity & profit shares"}
        description={lang === "ar" ? "النسبة محسوبة من رأس المال النشط" : "Derived from active capital"}
      >
        {(() => {
          const rows = allPartners
            .filter((p) => p.status === "active")
            .map((p) => {
              const o = data?.ownership.find((r) => r.partner_id === p.id);
              return { id: p.id, name: p.name, capital: Number(o?.total_contributions ?? 0), pct: Number(p.profit_share_percentage ?? o?.ownership_percentage ?? 0), paused: p.dividends_paused };
            })
            .sort((a, b) => b.pct - a.pct);
          if (!rows.length) return <p className="text-sm text-muted-foreground">{lang === "ar" ? "لا يوجد شركاء نشطون." : "No active partners."}</p>;
          return (
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              {rows.map((r) => (
                <div key={r.id} className="card-surface rounded-xl border border-border bg-card p-4 shadow-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="min-w-0 truncate font-semibold">{r.name}</span>
                    <span className="shrink-0 font-display text-lg font-bold tabular-nums text-primary">{formatPercent(r.pct, lang)}</span>
                  </div>
                  <div className="mt-2 h-2 overflow-hidden rounded-full bg-muted">
                    <div className="h-full rounded-full bg-primary transition-all" style={{ width: `${Math.min(100, Math.max(0, r.pct))}%` }} />
                  </div>
                  <div className="mt-2 flex items-center justify-between text-xs text-muted-foreground">
                    <span>{lang === "ar" ? "رأس المال" : "Capital"}: <span className="tabular-nums text-foreground">{formatMoney(r.capital, currency, lang)}</span></span>
                    {r.paused && <Badge variant="outline">{lang === "ar" ? "أرباح موقوفة" : "Paused"}</Badge>}
                  </div>
                </div>
              ))}
            </div>
          );
        })()}
      </CollapsibleSection>

      {(() => {
        const negatives = allPartners
          .map((p) => ({ p, bal: Number(data?.balances.find((r) => r.partner_id === p.id)?.balance ?? 0) }))
          .filter((x) => x.bal < 0);
        if (!negatives.length) return null;
        return (
          <CollapsibleSection
            icon={<AlertTriangle className="size-4 text-destructive" />}
            title={lang === "ar" ? "تسوية الأرصدة السالبة" : "Negative balance settlement"}
            description={lang === "ar" ? `${negatives.length} شريك برصيد مدين` : `${negatives.length} partner(s) owing`}
          >
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              {negatives.map(({ p, bal }) => (
                <div key={p.id} className="flex items-center justify-between gap-3 rounded-xl border border-border bg-card p-4 shadow-sm">
                  <div className="min-w-0">
                    <p className="truncate font-semibold">{p.name}</p>
                    <p className="font-display text-lg font-bold tabular-nums text-destructive">{formatMoney(bal, currency, lang)}</p>
                  </div>
                  <NegativeBalanceAlert partnerId={p.id} balance={bal} canSettle={isSuper} />
                </div>
              ))}
            </div>
          </CollapsibleSection>
        );
      })()}

      <CollapsibleSection
        icon={<Users className="size-4" />}
        title={lang === "ar" ? "سجل الشركاء" : "Partner register"}
        description={lang === "ar" ? "رأس المال، النسبة، الرصيد والإجراءات" : "Capital, share, balance and actions"}
      >
      <div className="mb-3 inline-flex rounded-lg border border-border bg-card p-1">
        {(["active", "archived"] as const).map((v) => (
          <button
            key={v}
            type="button"
            onClick={() => setView(v)}
            className={`min-h-11 rounded-md px-4 text-sm font-medium ${view === v ? "bg-primary text-primary-foreground" : "text-muted-foreground"}`}
          >
            {v === "active"
              ? `${lang === "ar" ? "النشطون" : "Active"} (${activeCount})`
              : `${lang === "ar" ? "الأرشيف / المعطلون" : "Archived"} (${allPartners.length - activeCount})`}
          </button>
        ))}
      </div>
      <SmartFilterBar search={q} onSearch={setQ} placeholder={lang === "ar" ? "ابحث بالاسم أو البريد أو الهاتف…" : "Search name, email, phone…"} />
      {pendingShareDate && (
        <p className="mb-3 flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 text-sm">
          <AlertTriangle className="mt-0.5 size-4 shrink-0 text-amber-600" aria-hidden />
          {lang === "ar"
            ? `فيه مساهمة رأس مال جديدة: النسب اللي فوق شغالة لحد آخر الشهر، والنسب الجديدة هتبدأ من ${formatDate(pendingShareDate, lang)} لوحدها.`
            : `A new capital contribution is waiting: the shares below apply to the end of the month; new shares start on ${formatDate(pendingShareDate, lang)} automatically.`}
        </p>
      )}

      {partners.length === 0 ? (
        <EmptyState message={t("partners.empty")} />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border">
          <Table className="min-w-[880px] table-fixed">
            <TableHeader className="bg-muted/45">
              <TableRow>
                <TableHead className="w-[24%] px-5 text-start">{t("common.name")}</TableHead>
                <TableHead className="w-[18%] whitespace-nowrap px-4 text-center">
                  {t("partners.capital")}
                </TableHead>
                <TableHead className="w-[14%] whitespace-nowrap px-4 text-center">
                  {t("partners.ownership")}
                </TableHead>
                <TableHead className="w-[18%] whitespace-nowrap px-4 text-center">
                  {t("partners.balance")}
                </TableHead>
                {can("partners.manage") && (
                  <TableHead className="w-[26%] min-w-60 whitespace-nowrap px-4 text-center">
                    {t("common.actions")}
                  </TableHead>
                )}
              </TableRow>
            </TableHeader>
            <TableBody>
              {partners.map((partner) => {
                const ownership = data?.ownership.find((row) => row.partner_id === partner.id);
                const balance = data?.balances.find((row) => row.partner_id === partner.id);
                return (
                  <TableRow key={partner.id} className="h-14 hover:bg-muted/25">
                    <TableCell className="px-5 py-3 font-medium">
                      <div className="flex min-w-0 items-center gap-2">
                        <button
                          type="button"
                          className="min-w-0 truncate text-start font-semibold text-primary underline-offset-4 hover:underline"
                          onClick={() => setStatementFor(partner as PartnerRow)}
                        >
                          {partner.name}
                        </button>
                        <Badge variant={partner.status === "active" ? "secondary" : "outline"} className="shrink-0">
                        {partner.status === "active"
                          ? lang === "ar" ? "نشط" : "Active"
                          : lang === "ar" ? "غير نشط" : "Inactive"}
                        </Badge>
                      </div>
                    </TableCell>
                    <TableCell className="whitespace-nowrap px-4 py-3 text-center tabular-nums">
                      {formatMoney(ownership?.total_contributions ?? 0, currency, lang)}
                      {Number(ownership?.open_loans ?? 0) > 0 && (
                        <span className="block text-xs text-muted-foreground">
                          {lang === "ar" ? "قرض مفتوح " : "Open loan "}{formatMoney(ownership?.open_loans ?? 0, currency, lang)}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="whitespace-nowrap px-4 py-3 text-center tabular-nums">
                      {formatPercent(ownership?.ownership_percentage ?? 0, lang)}
                    </TableCell>
                    <TableCell className="whitespace-nowrap px-4 py-3 text-center tabular-nums">
                      <span className={Number(balance?.balance ?? 0) < 0 ? "font-semibold text-destructive" : ""}>
                        {formatMoney(balance?.balance ?? 0, currency, lang)}
                      </span>
                    </TableCell>
                    {can("partners.manage") && (
                      <TableCell className="px-4 py-2 text-center">
                        <TooltipProvider delayDuration={180}>
                          <div className="flex flex-nowrap items-center justify-center gap-1">
                            {isSuper && (
                              <PartnerActionTip label={t("partners.addCapital")}>
                                <Button size="icon" variant="outline" className="h-8 w-8" aria-label={t("partners.addCapital")} onClick={() => setCapitalFor({ id: partner.id, name: partner.name })}>
                                  <CirclePlus />
                                </Button>
                              </PartnerActionTip>
                            )}
                            <PartnerActionTip label={t("partners.statement")}>
                              <Button size="icon" variant="ghost" className="h-8 w-8 text-primary" aria-label={t("partners.statement")} onClick={() => setStatementFor(partner as PartnerRow)}>
                                <FileText />
                              </Button>
                            </PartnerActionTip>
                            {isSuper && (
                              <PartnerActionTip label={t("common.edit")}>
                                <Button size="icon" variant="ghost" className="h-8 w-8" aria-label={t("common.edit")} onClick={() => setEditPartner({
                                  id: partner.id,
                                  name: partner.name,
                                  share: partner.profit_share_percentage == null ? "" : String(partner.profit_share_percentage),
                                })}>
                                  <Pencil />
                                </Button>
                              </PartnerActionTip>
                            )}
                            {isSuper && partner.status === "active" && (() => {
                              const pauseLabel = partner.dividends_paused
                                ? lang === "ar" ? "استئناف توزيع الأرباح" : "Resume dividends"
                                : lang === "ar" ? "إيقاف توزيع الأرباح" : "Pause dividends";
                              return (
                                <PartnerActionTip label={pauseLabel}>
                                  <Button
                                    size="icon"
                                    variant={partner.dividends_paused ? "default" : "ghost"}
                                    className="h-8 w-8"
                                    aria-label={pauseLabel}
                                    disabled={togglePause.isPending}
                                    onClick={() => togglePause.mutate({ id: partner.id, paused: !partner.dividends_paused })}
                                  >
                                    {partner.dividends_paused ? <PlayCircle /> : <PauseCircle />}
                                  </Button>
                                </PartnerActionTip>
                              );
                            })()}
                            {isSuper && partner.status === "active" && (
                              <PartnerActionTip label={lang === "ar" ? "تصفية الشراكة" : "Liquidate partnership"}>
                                <Button
                                  size="icon"
                                  variant="ghost"
                                  className="h-8 w-8 text-destructive hover:bg-destructive/10 hover:text-destructive"
                                  aria-label={lang === "ar" ? "تصفية الشراكة" : "Liquidate partnership"}
                                  onClick={() => setLiquidationFor({
                                    ...partner,
                                    profit_share_percentage: Number(
                                      partner.profit_share_percentage ?? ownership?.ownership_percentage ?? 0,
                                    ),
                                  } as LiquidationPartner)}
                                >
                                  <RefreshCcw />
                                </Button>
                              </PartnerActionTip>
                            )}
                            {isSuper && (
                              <PartnerActionTip label={lang === "ar" ? "حذف الشريك" : "Delete partner"}>
                                <Button
                                  size="icon"
                                  variant="ghost"
                                  className="h-8 w-8 text-destructive hover:bg-destructive/10 hover:text-destructive"
                                  aria-label={lang === "ar" ? "حذف الشريك" : "Delete partner"}
                                  onClick={() => setDeleteFor({ id: partner.id, name: partner.name })}
                                >
                                  <Trash2 />
                                </Button>
                              </PartnerActionTip>
                            )}
                          </div>
                        </TooltipProvider>
                      </TableCell>
                    )}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      </CollapsibleSection>

      {data && data.contributions.length > 0 && (
        <CollapsibleSection
          icon={<Landmark className="size-4" />}
          title={lang === "ar" ? "سجل المساهمات والقروض" : "Contributions & loans log"}
          description={`${data.contributions.length} ${lang === "ar" ? "مساهمة" : "entries"}`}
          defaultOpen={false}
        >
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-40 whitespace-nowrap text-center">{t("common.date")}</TableHead>
                <TableHead className="min-w-48 text-start">{t("partners.title")}</TableHead>
                <TableHead className="w-40 whitespace-nowrap text-end">
                  {t("common.amount")}
                </TableHead>
                <TableHead className="w-32 whitespace-nowrap text-center">{lang === "ar" ? "النوع" : "Type"}</TableHead>
                <TableHead className="min-w-48 text-start">{lang === "ar" ? "تأثيرها" : "Effect"}</TableHead>
                <TableHead className="min-w-40 text-start">{lang === "ar" ? "مرجع" : "Ref"}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.contributions.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="w-40 whitespace-nowrap text-center">
                    {formatDate(row.contribution_date, lang)}
                  </TableCell>
                  <TableCell className="min-w-48 font-medium">
                    {partners.find((partner) => partner.id === row.partner_id)?.name ?? "—"}
                  </TableCell>
                  <TableCell className="w-40 whitespace-nowrap text-end tabular-nums">
                    {formatMoney(row.amount, currency, lang)}
                  </TableCell>
                  <TableCell className="w-32 whitespace-nowrap text-center">
                    <Badge variant={row.kind === "loan" ? "outline" : "secondary"}>
                      {row.kind === "loan" ? (lang === "ar" ? "قرض" : "Loan") : lang === "ar" ? "رأس مال" : "Capital"}
                    </Badge>
                  </TableCell>
                  <TableCell className="min-w-48 text-xs text-muted-foreground">
                    {row.kind === "loan"
                      ? Number(row.amount) - Number(row.repaid_amount) > 0
                        ? lang === "ar"
                          ? `اترد ${formatMoney(row.repaid_amount, currency, lang)} · باقي ${formatMoney(Number(row.amount) - Number(row.repaid_amount), currency, lang)}`
                          : `Repaid ${formatMoney(row.repaid_amount, currency, lang)} · ${formatMoney(Number(row.amount) - Number(row.repaid_amount), currency, lang)} left`
                        : lang === "ar" ? "اترد بالكامل" : "Fully repaid"
                      : row.effective_from > businessToday()
                        ? <span className="font-medium text-amber-600">{lang === "ar" ? `النسب الجديدة من ${formatDate(row.effective_from, lang)}` : `New shares from ${formatDate(row.effective_from, lang)}`}</span>
                        : lang === "ar" ? `في النسب من ${formatDate(row.effective_from, lang)}` : `In shares since ${formatDate(row.effective_from, lang)}`}
                  </TableCell>
                  <TableCell className="min-w-40 text-muted-foreground">{row.reference ?? "—"}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
        </CollapsibleSection>
      )}
      </div>

      <PartnerStatementDialog partner={statementFor} onClose={() => setStatementFor(null)} />
      <PartnerLiquidationDialog
        partner={liquidationFor}
        partners={partners.map((partner) => ({
          ...partner,
          profit_share_percentage: Number(
            partner.profit_share_percentage ??
              data?.ownership.find((row) => row.partner_id === partner.id)?.ownership_percentage ??
              0,
          ),
        })) as LiquidationPartner[]}
        balance={(() => {
          // Liquidation settles capital + balance.
          const row = data?.balances.find((r) => r.partner_id === liquidationFor?.id);
          return Number(row?.balance ?? 0) + Number(row?.capital ?? 0);
        })()}
        currency={currency}
        lang={lang}
        onClose={() => setLiquidationFor(null)}
      />

      <Dialog open={Boolean(editPartner)} onOpenChange={(value) => !value && setEditPartner(null)}>
        <DialogContent>
          <DialogHeader><DialogTitle>{lang === "ar" ? "تعديل الشريك" : "Edit partner"}</DialogTitle></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2"><Label>{t("common.name")}</Label><Input value={editPartner?.name ?? ""} onChange={(event) => setEditPartner((current) => current ? { ...current, name: event.target.value } : current)} /></div>
            <div className="space-y-2"><Label>{lang === "ar" ? "نسبة الأرباح %" : "Profit share %"}</Label><Input type="number" min="0" max="100" step="0.0001" value={editPartner?.share ?? ""} onChange={(event) => setEditPartner((current) => current ? { ...current, share: event.target.value } : current)} /><p className="text-xs text-muted-foreground">{lang === "ar" ? "اتركها فارغة لاستخدام النسبة المحسوبة من رأس المال." : "Leave blank to use the capital-derived share."}</p></div>
          </div>
          <DialogFooter><Button onClick={() => updatePartner.mutate()} disabled={!editPartner?.name.trim() || updatePartner.isPending}>{t("common.save")}</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(deleteFor)} onOpenChange={(value) => !value && setDeleteFor(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{lang === "ar" ? "حذف الشريك نهائيًا" : "Delete partner permanently"}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="text-sm">
              {lang === "ar"
                ? `هل أنت متأكد من حذف «${deleteFor?.name}» نهائيًا؟`
                : `Are you sure you want to permanently delete "${deleteFor?.name}"?`}
            </p>
            <p className="rounded-md border border-border bg-muted/40 p-3 text-xs text-muted-foreground">
              {lang === "ar"
                ? "الحذف متاح فقط لو الشريك مالوش أي مساهمات رأس مال أو حركات مالية أو توزيعات أرباح أو فواتير حساب أو طلبات سحب. لو فيه أي سجل مالي مرتبط بيه، الحذف هيترفض برسالة توضح السبب — وساعتها استخدم «التصفية» بدل الحذف."
                : "Deletion is only possible if the partner has no capital contributions, financial transactions, profit distributions, tab orders or withdrawal requests. If any linked financial record exists, deletion is refused with a clear reason — use \"Liquidate\" instead."}
            </p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteFor(null)}>
              {lang === "ar" ? "إلغاء" : "Cancel"}
            </Button>
            <Button
              variant="destructive"
              disabled={deletePartner.isPending}
              onClick={() => deleteFor && deletePartner.mutate(deleteFor.id)}
            >
              {lang === "ar" ? "نعم، احذف نهائيًا" : "Yes, delete permanently"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ContributionDialog partner={capitalFor} onClose={() => setCapitalFor(null)} currency={currency} lang={lang} />

      <WithdrawalsSection currency={currency} />
    </div>
  );
}

function PartnerActionTip({ label, children }: { label: string; children: ReactNode }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>{children}</TooltipTrigger>
      <TooltipContent side="top">
        <p>{label}</p>
      </TooltipContent>
    </Tooltip>
  );
}

const STATUS_LABELS: Record<string, { en: string; ar: string }> = {
  pending: { en: "Pending review", ar: "قيد المراجعة" },
  approved: { en: "Approved", ar: "مقبول" },
  rejected: { en: "Rejected", ar: "مرفوض" },
};

function WithdrawalsSection({ currency }: { currency: string }) {
  const { lang } = useI18n();
  const { can } = useAuth();
  const ar = lang === "ar";
  const queryClient = useQueryClient();
  const canReview = can("partners.manage_withdrawals");
  const [requestOpen, setRequestOpen] = useState(false);
  const [form, setForm] = useState({ amount: "", method: "cash", notes: "" });
  const [reviewFor, setReviewFor] = useState<string | null>(null);
  const [review, setReview] = useState({ account_id: "", note: "" });

  const { data: myPartnerId } = useQuery({
    queryKey: ["current-partner"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("current_partner_id");
      if (error) throw error;
      return (data as string | null) ?? null;
    },
  });

  const { data: requests } = useQuery({
    queryKey: ["withdrawal-requests"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("partner_withdrawal_requests")
        .select(
          "id, partner_id, amount, method, status, notes, review_note, created_at, reviewed_at, partners(name)",
        )
        .order("created_at", { ascending: false })
        .limit(50);
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: accounts } = useQuery({
    queryKey: ["cash-accounts-simple"],
    enabled: canReview,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("cash_accounts")
        .select("id, name, name_ar, is_active")
        .eq("is_active", true)
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["withdrawal-requests"] });
    queryClient.invalidateQueries({ queryKey: ["partners"] });
    queryClient.invalidateQueries({ queryKey: ["treasury-overview"] });
  };

  const submitRequest = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("request_partner_withdrawal", {
        _amount: Number(form.amount),
        _method: form.method,
        ...(form.notes ? { _notes: form.notes } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setRequestOpen(false);
      setForm({ amount: "", method: "cash", notes: "" });
      invalidate();
      toast.success(ar ? "تم إرسال طلب السحب للمراجعة." : "Withdrawal request submitted.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const decide = useMutation({
    mutationFn: async (input: { id: string; approve: boolean }) => {
      const { error } = await supabase.rpc("review_partner_withdrawal", {
        _request_id: input.id,
        _approve: input.approve,
        ...(review.note ? { _note: review.note } : {}),
        ...(input.approve && review.account_id ? { _account_id: review.account_id } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setReviewFor(null);
      setReview({ account_id: "", note: "" });
      invalidate();
      toast.success(ar ? "تم تنفيذ القرار." : "Decision recorded.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const rows = requests ?? [];

  return (
    <Card className="mt-6">
      <CardHeader className="flex flex-row items-center justify-between gap-3">
        <div>
          <CardTitle className="text-base">{ar ? "طلبات السحب" : "Withdrawal requests"}</CardTitle>
          <p className="text-sm text-muted-foreground">
            {ar
              ? "الشريك يطلب سحب من رصيده والسوبر أدمن يوافق أو يرفض، والموافقة بتخرج فلوس فعلية من الخزنة."
              : "Partners request a withdrawal; approval posts a real cash outflow from the treasury."}
          </p>
        </div>
        {myPartnerId && (
          <Dialog open={requestOpen} onOpenChange={setRequestOpen}>
            <DialogTrigger asChild>
              <Button size="sm">{ar ? "طلب سحب" : "Request withdrawal"}</Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>{ar ? "طلب سحب" : "Request withdrawal"}</DialogTitle>
              </DialogHeader>
              <div className="space-y-3">
                <div className="space-y-2">
                  <Label>{ar ? "المبلغ" : "Amount"}</Label>
                  <Input
                    type="number"
                    min="0.01"
                    step="0.01"
                    value={form.amount}
                    onChange={(event) => setForm({ ...form, amount: event.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label>{ar ? "طريقة الاستلام" : "Method"}</Label>
                  <Select
                    value={form.method}
                    onValueChange={(value) => setForm({ ...form, method: value })}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="cash">{ar ? "كاش" : "Cash"}</SelectItem>
                      <SelectItem value="transfer">
                        {ar ? "تحويل بنكي" : "Bank transfer"}
                      </SelectItem>
                      <SelectItem value="wallet">{ar ? "محفظة إلكترونية" : "E-wallet"}</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label>{ar ? "ملاحظة" : "Note"}</Label>
                  <Input
                    value={form.notes}
                    onChange={(event) => setForm({ ...form, notes: event.target.value })}
                  />
                </div>
              </div>
              <DialogFooter>
                <Button
                  onClick={() => submitRequest.mutate()}
                  disabled={!form.amount || Number(form.amount) <= 0 || submitRequest.isPending}
                >
                  {ar ? "إرسال" : "Submit"}
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        )}
      </CardHeader>
      <CardContent>
        {rows.length === 0 ? (
          <EmptyState message={ar ? "لا توجد طلبات سحب." : "No withdrawal requests yet."} />
        ) : (
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-40 whitespace-nowrap text-center">
                    {ar ? "التاريخ" : "Date"}
                  </TableHead>
                  <TableHead className="min-w-48 text-start">{ar ? "الشريك" : "Partner"}</TableHead>
                  <TableHead className="w-40 whitespace-nowrap text-end">
                    {ar ? "المبلغ" : "Amount"}
                  </TableHead>
                  <TableHead className="w-36 whitespace-nowrap text-center">
                    {ar ? "الطريقة" : "Method"}
                  </TableHead>
                  <TableHead className="w-36 whitespace-nowrap text-center">
                    {ar ? "الحالة" : "Status"}
                  </TableHead>
                  {canReview && (
                    <TableHead className="w-36 whitespace-nowrap text-center">
                      {ar ? "إجراء" : "Action"}
                    </TableHead>
                  )}
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id}>
                    <TableCell className="w-40 whitespace-nowrap text-center">
                      {formatDate(row.created_at, lang)}
                    </TableCell>
                    <TableCell className="min-w-48 font-medium">{row.partners?.name ?? "—"}</TableCell>
                    <TableCell className="w-40 whitespace-nowrap text-end tabular-nums">
                      {formatMoney(row.amount, currency, lang)}
                    </TableCell>
                    <TableCell className="w-36 text-center text-muted-foreground">{row.method}</TableCell>
                    <TableCell className="w-36 text-center">
                      <Badge
                        variant={
                          row.status === "approved"
                            ? "default"
                            : row.status === "rejected"
                              ? "destructive"
                              : "secondary"
                        }
                      >
                        {STATUS_LABELS[row.status]?.[ar ? "ar" : "en"] ?? row.status}
                      </Badge>
                      {row.review_note && (
                        <span className="ms-2 text-xs text-muted-foreground">
                          {row.review_note}
                        </span>
                      )}
                    </TableCell>
                    {canReview && (
                      <TableCell className="w-36 text-center">
                        {row.status === "pending" ? (
                          <Button size="sm" variant="outline" onClick={() => setReviewFor(row.id)}>
                            {ar ? "مراجعة" : "Review"}
                          </Button>
                        ) : (
                          <span className="text-xs text-muted-foreground">
                            {row.reviewed_at ? formatDate(row.reviewed_at, lang) : "—"}
                          </span>
                        )}
                      </TableCell>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </CardContent>

      <Dialog open={Boolean(reviewFor)} onOpenChange={(value) => !value && setReviewFor(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{ar ? "مراجعة طلب السحب" : "Review withdrawal"}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label>{ar ? "الحساب النقدي (للصرف)" : "Cash account (for payout)"}</Label>
              <Select
                value={review.account_id}
                onValueChange={(value) => setReview({ ...review, account_id: value })}
              >
                <SelectTrigger>
                  <SelectValue placeholder={ar ? "الحساب الافتراضي" : "Default account"} />
                </SelectTrigger>
                <SelectContent>
                  {(accounts ?? []).map((account) => (
                    <SelectItem key={account.id} value={account.id}>
                      {ar ? (account.name_ar ?? account.name) : account.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label>{ar ? "ملاحظة / سبب الرفض" : "Note / rejection reason"}</Label>
              <Input
                value={review.note}
                onChange={(event) => setReview({ ...review, note: event.target.value })}
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              variant="destructive"
              disabled={decide.isPending}
              onClick={() => decide.mutate({ id: reviewFor!, approve: false })}
            >
              {ar ? "رفض" : "Reject"}
            </Button>
            <Button
              disabled={decide.isPending}
              onClick={() => decide.mutate({ id: reviewFor!, approve: true })}
            >
              {ar ? "موافقة وصرف" : "Approve & pay"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}

/**
 * Partner-scoped profit card. Reads a dedicated RPC that only ever returns the
 * signed-in partner's own percentage and amount — never another partner's data.
 */
function NegativeBalanceAlert({ partnerId, balance, canSettle }: { partnerId: string; balance: number; canSettle: boolean }) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const settle = useMutation({
    mutationFn: async (mode: "carry" | "cash") => {
      const { error } = await supabase.rpc("settle_partner_negative_balance", { _partner_id: partnerId, _mode: mode });
      if (error) throw error;
      return mode;
    },
    onSuccess: (mode) => {
      qc.invalidateQueries();
      toast.success(mode === "cash" ? (ar ? "سُجل السداد النقدي في الخزنة" : "Cash repayment recorded") : (ar ? "سيُخصم من الأرباح القادمة" : "Will be deducted from upcoming dividends"));
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  return (
    <div className="mt-2 whitespace-normal rounded-lg border border-destructive/40 bg-destructive/10 p-2 text-start text-xs text-destructive">
      <p className="font-semibold">{ar ? "تنبيه: رصيد سالب بعد إعادة الاحتساب" : "Warning: negative balance after recalculation"}</p>
      {canSettle && (
        <div className="mt-1.5 flex flex-wrap gap-1.5">
          <Button size="sm" variant="outline" className="h-8" disabled={settle.isPending} onClick={() => settle.mutate("carry")}>
            {ar ? "ترحيل للخصم من الأرباح القادمة" : "Deduct from upcoming dividends"}
          </Button>
          <Button size="sm" variant="destructive" className="h-8" disabled={settle.isPending} onClick={() => settle.mutate("cash")}>
            {ar ? `تسجيل سداد نقدي يدوي (${Math.abs(balance).toFixed(2)})` : `Record cash repayment (${Math.abs(balance).toFixed(2)})`}
          </Button>
        </div>
      )}
    </div>
  );
}
