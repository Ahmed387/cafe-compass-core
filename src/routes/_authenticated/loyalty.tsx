import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Coins, Gift, Plus, RotateCcw, Save, Target, Trash2, UserPlus, Wallet } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Pagination } from "@/components/shared";
import { InfoTip } from "@/components/shared/InfoTip";
import { KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Progress } from "@/components/ui/progress";
import { Switch } from "@/components/ui/switch";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { nextTier, parseCashbackConfig, tierError, type CashbackConfig } from "@/lib/cashback-tiers";
import { SectionTitle } from "@/components/shared/SectionTitle";

export const Route = createFileRoute("/_authenticated/loyalty")({
  head: () => ({
    meta: [
      { title: "Customers & cashback — 20s Coffee" },
      { name: "description", content: "Customer cards and the target cashback wallet for 20s Coffee." },
      { property: "og:title", content: "Customers & cashback — 20s Coffee" },
      { property: "og:description", content: "Spend-based cashback that customers use on their next bills." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: CashbackPage,
});

type Customer = {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  barcode: string;
  wallet_balance: number;
  cashback_progress: number;
  /** 0-based cashback level the customer is working toward. */
  cashback_level: number;
  total_spent: number;
  visits: number;
  /** Visit stamps toward the next free drink. */
  points_balance: number | null;
  last_visit_at: string | null;
};

const PAGE_SIZE = 25;

function CashbackPage() {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const { can, me } = useAuth();
  const qc = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number | string | null | undefined) => formatMoney(Number(v ?? 0), currency, lang);
  const isSuperAdmin = Boolean(me?.isRoot || me?.roleNames.includes("Super Admin"));
  const canView = can("loyalty.view") || isSuperAdmin;

  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [historyFor, setHistoryFor] = useState<Customer | null>(null);
  const [editFor, setEditFor] = useState<Customer | null>(null);
  const [newOpen, setNewOpen] = useState(false);

  const config = useQuery({
    queryKey: ["cashback-settings"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("cashback_settings");
      if (error) throw error;
      return parseCashbackConfig(data);
    },
  });

  const customers = useQuery({
    queryKey: ["cashback-customers", search, page],
    enabled: canView,
    queryFn: async () => {
      let query = supabase
        .from("customers")
        .select("id, code, name, phone, barcode, wallet_balance, cashback_progress, cashback_level, total_spent, visits, points_balance, last_visit_at", { count: "exact" })
        .eq("is_active", true)
        .order("wallet_balance", { ascending: false })
        .order("created_at", { ascending: true })
        .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);
      const term = search.trim().slice(0, 80).replace(/[%_,()]/g, " ").trim();
      if (term) query = query.or(`name.ilike.%${term}%,phone.ilike.%${term}%,code.ilike.%${term}%,barcode.ilike.%${term}%`);
      const { data, error, count } = await query;
      if (error) throw error;
      return { rows: (data ?? []) as Customer[], total: count ?? 0 };
    },
  });

  // Customers who are also partners: their tab invoices are "a partner with an
  // invoice on their account", never visits (owner's rule 2026-10-22).
  const partnerCustomers = useQuery({
    queryKey: ["loyalty-partner-customers"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("partners")
        .select("customer_id, partner_tab_orders(total_amount, settled_amount, is_settled)")
        .not("customer_id", "is", null);
      if (error) throw error;
      const open = new Map<string, number>();
      for (const row of data ?? []) {
        const tabs = (row.partner_tab_orders ?? []) as Array<{ total_amount: number; settled_amount: number; is_settled: boolean }>;
        open.set(
          row.customer_id as string,
          tabs.filter((tab) => !tab.is_settled).reduce((sum, tab) => sum + Math.max(Number(tab.total_amount) - Number(tab.settled_amount ?? 0), 0), 0),
        );
      }
      return open;
    },
  });

  // Money the café owes customers in wallets (a liability until they spend it).
  const liability = useQuery({
    queryKey: ["cashback-liability"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.from("customers").select("wallet_balance").gt("wallet_balance", 0);
      if (error) throw error;
      return (data ?? []).reduce((s, r) => s + Number(r.wallet_balance), 0);
    },
  });

  if (!canView) return <NoPermission message={t("common.noAccess")} />;
  const rows = customers.data?.rows ?? [];
  const cfg = config.data;

  return (
    <div className="space-y-5">
      <PageHeader
        title={ar ? "العملاء والكاش باك" : "Customers & cashback"}
        description={ar ? "العميل بيجمع كاش باك في محفظته كل ما يوصل لمبلغ معين، ويستخدمه في فواتيره الجاية." : "Customers earn cashback into a wallet every time they reach a spend target, and use it on later bills."}
        action={canView ? <Button onClick={() => setNewOpen(true)}><UserPlus className="me-1 size-4" />{ar ? "عميل جديد" : "New customer"}</Button> : undefined}
      />

      <KpiGrid cols={3}>
        <KpiCard label={ar ? "القاعدة الحالية" : "Current rule"} icon={<Target className="size-4" />}
          value={cfg ? (cfg.enabled ? (ar ? `شغّال · ${cfg.tiers.length} ${cfg.tiers.length === 1 ? "مستوى" : "مستويات"}` : `On · ${cfg.tiers.length} level${cfg.tiers.length === 1 ? "" : "s"}`) : ar ? "متوقف" : "Off") : "—"}
          tone={cfg?.enabled ? "good" : undefined}
          formula={ar ? "متوقف يعني محدش بياخد كاش باك دلوقتي. شغّال يعني كل ما مشتريات العميل توصل لمستوى، مكافأته بتنزل في محفظته لوحدها." : "Off means nobody earns cashback now. On means each level a customer reaches pays its reward into their wallet."} />
        <KpiCard label={ar ? "فلوس في محافظ العملاء" : "Owed in customer wallets"} icon={<Wallet className="size-4" />}
          value={money(liability.data)} tone="warn"
          formula={ar ? "مجموع الفلوس اللي في محافظ كل العملاء ولسه ماستخدموهاش في فواتيرهم." : "Total cashback in every customer's wallet that hasn't been used on a bill yet."} />
        <KpiCard label={ar ? "عدد العملاء" : "Customers"} icon={<Gift className="size-4" />} value={customers.data?.total ?? "—"} />
      </KpiGrid>

      {isSuperAdmin && cfg && (
        <CashbackRuleCard
          config={cfg}
          lang={lang}
          money={money}
          walletTotal={liability.data ?? 0}
          onSaved={() => {
            qc.invalidateQueries({ queryKey: ["cashback-settings"] });
            qc.invalidateQueries({ queryKey: ["cashback-customers"] });
            qc.invalidateQueries({ queryKey: ["cashback-liability"] });
          }}
        />
      )}
      {/* Visit stamps were retired on 2026-10-20: cashback is the one loyalty rule. Their data stays. */}

      <section className="space-y-3">
        <Input placeholder={ar ? "دوّر بالاسم أو الموبايل أو الكود" : "Search name, phone or code"} value={search}
          onChange={(e) => { setSearch(e.target.value); setPage(0); }} className="max-w-sm" />
        {rows.length === 0 ? (
          <EmptyState message={ar ? "مفيش عملاء" : "No customers"} />
        ) : (
          <div className="overflow-x-auto rounded-lg border border-border bg-card">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t("common.name")}</TableHead>
                  <TableHead>{t("common.phone")}</TableHead>
                  <TableHead className="text-end">{ar ? "المحفظة" : "Wallet"}</TableHead>
                  <TableHead className="min-w-40">{ar ? "للمكافأة الجاية" : "To next reward"}</TableHead>
                  <TableHead className="text-center">{ar ? "الزيارات" : "Visits"}</TableHead>
                  <TableHead className="text-end">{t("common.actions")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => {
                  const progress = Math.max(Number(row.cashback_progress), 0);
                  const next = cfg ? nextTier(cfg.tiers, progress, Number(row.cashback_level ?? 0)) : null;
                  const partnerTab = partnerCustomers.data?.get(row.id);
                  return (
                    <TableRow key={row.id}>
                      <TableCell className="font-medium">{row.name}<span className="block font-mono text-xs text-muted-foreground">{row.code}</span></TableCell>
                      <TableCell>{row.phone ?? "—"}</TableCell>
                      <TableCell className="text-end"><Badge variant="secondary" className="tabular-nums">{money(row.wallet_balance)}</Badge></TableCell>
                      <TableCell>
                        {cfg?.enabled && next ? (
                          <div className="space-y-1">
                            <Progress value={next.done * 100} className="h-1.5" />
                            <p className="text-xs tabular-nums text-muted-foreground">
                              {cfg.tiers.length > 1 && (ar ? `مستوى ${next.index + 1} · ` : `Level ${next.index + 1} · `)}
                              {ar ? "فاضل" : "Left"} {money(next.left)} {ar ? "وياخد" : "to get"} {money(next.tier.reward)}
                            </p>
                          </div>
                        ) : <span className="text-xs text-muted-foreground">—</span>}
                      </TableCell>
                      <TableCell className="text-center tabular-nums">
                        {partnerTab === undefined ? row.visits : (
                          <Badge variant="outline" className="whitespace-nowrap border-amber-400/60 text-amber-800 dark:text-amber-300">
                            {partnerTab > 0
                              ? `${ar ? "شريك وعليه فاتورة" : "Partner, open tab"} · ${money(partnerTab)}`
                              : ar ? "شريك" : "Partner"}
                          </Badge>
                        )}
                      </TableCell>
                      <TableCell className="space-x-2 whitespace-nowrap text-end">
                        <Button size="sm" variant="secondary" onClick={() => setHistoryFor(row)}>{ar ? "الحركات" : "History"}</Button>
                        {isSuperAdmin && <Button size="sm" variant="outline" onClick={() => setEditFor(row)}>{ar ? "تعديل" : "Edit"}</Button>}
                        {isSuperAdmin && (Number(row.cashback_progress) > 0 || Number(row.cashback_level) > 0) && (
                          <ResetCashbackButton customerId={row.id} lang={lang} onDone={() => qc.invalidateQueries({ queryKey: ["cashback-customers"] })} />
                        )}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
            <Pagination page={page} pageSize={PAGE_SIZE} total={customers.data?.total ?? 0} onPage={setPage} loading={customers.isFetching} />
          </div>
        )}
      </section>

      <WalletHistoryDialog customer={historyFor} onClose={() => setHistoryFor(null)} money={money} lang={lang} />
      <EditCustomerDialog customer={editFor} onClose={() => setEditFor(null)} money={money} lang={lang} />
      <NewCustomerDialog open={newOpen} onOpenChange={setNewOpen} lang={lang} />
    </div>
  );
}

type TierDraft = { target: string; reward: string };

function CashbackRuleCard({ config, lang, money, walletTotal, onSaved }: {
  config: CashbackConfig; lang: "ar" | "en"; money: (v: number) => string; walletTotal: number; onSaved: () => void;
}) {
  const ar = lang === "ar";
  const toDraft = (c: CashbackConfig): TierDraft[] =>
    c.tiers.length > 0 ? c.tiers.map((t) => ({ target: String(t.target), reward: String(t.reward) })) : [{ target: "", reward: "" }];
  const [enabled, setEnabled] = useState(config.enabled);
  const [tiers, setTiers] = useState<TierDraft[]>(toDraft(config));
  useEffect(() => { setEnabled(config.enabled); setTiers(toDraft(config)); }, [config]);

  const parsed = tiers.map((t) => ({ target: Number(t.target), reward: Number(t.reward) }));
  const problem = tierError(parsed, lang);
  // Turning it off never needs valid numbers: the last levels are kept.
  const canSave = !problem || !enabled;

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("set_cashback_tiers" as never, {
        _enabled: enabled,
        _tiers: problem ? null : parsed,
      } as never);
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "اتحفظت مستويات الكاش باك" : "Cashback levels saved"); onSaved(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const setTier = (i: number, key: keyof TierDraft, value: string) =>
    setTiers((prev) => prev.map((t, j) => (j === i ? { ...t, [key]: value } : t)));

  return (
    <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm sm:p-5">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-1.5">
          <SectionTitle icon={Coins}>{ar ? "مستويات الكاش باك" : "Cashback levels"}</SectionTitle>
          <InfoTip title={ar ? "إزاي بيشتغل؟" : "How does it work?"}>
            {ar
              ? "مشتريات العميل بتتجمع. كل ما يوصل لتارجت مستوى، مكافأة المستوى ده بتنزل في محفظته لوحدها. بعد آخر مستوى بيبدأ من الأول. الفلوس دي بتتصرف بس في فاتورة العميل نفسه، ومش بتتسحب كاش."
              : "Spend builds up. Each level target reached pays that level's reward into the wallet automatically. After the last level it starts again. Wallet money only pays the customer's own bills, never cash."}
          </InfoTip>
        </div>
        <label className="flex items-center gap-2 text-sm">{ar ? "مفعّل" : "Enabled"}<Switch checked={enabled} onCheckedChange={setEnabled} /></label>
      </div>

      <div className="space-y-2">
        <div className="hidden grid-cols-[4rem_1fr_1fr_2.5rem] gap-2 px-1 text-xs font-medium text-muted-foreground sm:grid">
          <span>{ar ? "المستوى" : "Level"}</span>
          <span>{ar ? "لما مشترياته توصل" : "When spend reaches"}</span>
          <span>{ar ? "ياخد في محفظته" : "Gets in wallet"}</span>
          <span />
        </div>
        {tiers.map((tier, i) => (
          <div key={i} className="grid grid-cols-[4rem_1fr_1fr_2.5rem] items-center gap-2">
            <span className="text-sm font-semibold">{ar ? `مستوى ${i + 1}` : `Level ${i + 1}`}</span>
            <Input aria-label={ar ? `تارجت المستوى ${i + 1}` : `Level ${i + 1} target`} inputMode="decimal" value={tier.target}
              onChange={(e) => setTier(i, "target", e.target.value)} />
            <Input aria-label={ar ? `مكافأة المستوى ${i + 1}` : `Level ${i + 1} reward`} inputMode="decimal" value={tier.reward}
              onChange={(e) => setTier(i, "reward", e.target.value)} />
            <Button type="button" size="icon" variant="ghost" disabled={tiers.length === 1}
              aria-label={ar ? "شيل المستوى" : "Remove level"}
              onClick={() => setTiers((prev) => prev.filter((_, j) => j !== i))}>
              <Trash2 className="size-4" />
            </Button>
          </div>
        ))}
        <div className="flex flex-wrap items-center justify-between gap-2 pt-1">
          <Button type="button" size="sm" variant="outline" disabled={tiers.length >= 10}
            onClick={() => setTiers((prev) => [...prev, { target: "", reward: "" }])}>
            <Plus className="me-1 size-4" />{ar ? "ضيف مستوى" : "Add level"}
          </Button>
          <Button disabled={!canSave || save.isPending} onClick={() => save.mutate()}><Save className="me-1 size-4" />{ar ? "احفظ" : "Save"}</Button>
        </div>
        <p className={`text-xs ${problem && enabled ? "text-destructive" : "text-muted-foreground"}`}>
          {problem
            ? problem
            : ar
              ? `مثال: عميل مشترياته وصلت ${money(parsed[0]!.target)} ياخد ${money(parsed[0]!.reward)}${parsed[1] ? `، ولما توصل ${money(parsed[1].target)} ياخد ${money(parsed[1].reward)} كمان` : ""}. بعد آخر مستوى بيبدأ من الأول.`
              : `E.g. at ${money(parsed[0]!.target)} spend the customer gets ${money(parsed[0]!.reward)}${parsed[1] ? `, at ${money(parsed[1].target)} another ${money(parsed[1].reward)}` : ""}. After the last level it starts again.`}
        </p>
      </div>

      <div className="mt-3 space-y-2 border-t pt-3">
        <div className="flex flex-wrap items-center gap-2">
          <ResetCashbackButton lang={lang} onDone={onSaved} />
          <span className="text-xs text-muted-foreground">
            {ar ? "بيرجّع مشتريات كل العملاء للصفر ويبدأوا من المستوى الأول. فلوس المحافظ زي ما هي." : "Restarts everyone's spend at zero and level 1. Wallet money stays."}
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <ZeroWalletsButton lang={lang} total={walletTotal} money={money} onDone={onSaved} />
          <span className="text-xs text-muted-foreground">
            {ar ? "بيخلي رصيد كل المحافظ صفر. كل خصم بيتسجل في حركات العميل باسمك، ومفيش حاجة بتتمسح." : "Sets every wallet to zero. Each deduction is logged in the customer's history under your name; nothing is deleted."}
          </span>
        </div>
      </div>
    </section>
  );
}

/** Zero every customer wallet (Super Admin). Two taps, no browser dialog. */
function ZeroWalletsButton({ lang, total, money, onDone }: {
  lang: "ar" | "en"; total: number; money: (v: number) => string; onDone: () => void;
}) {
  const ar = lang === "ar";
  const [armed, setArmed] = useState(false);
  useEffect(() => {
    if (!armed) return;
    const timer = setTimeout(() => setArmed(false), 5000);
    return () => clearTimeout(timer);
  }, [armed]);
  const zero = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc("reset_all_wallets" as never, {
        _reason: ar ? "صفّرها السوبر أدمن من صفحة العملاء" : "Zeroed by the Super Admin from the customers page",
      } as never);
      if (error) throw error;
      const v = (data ?? {}) as { customers?: number; total?: number };
      return { customers: Number(v.customers ?? 0), total: Number(v.total ?? 0) };
    },
    onSuccess: (r) => {
      setArmed(false);
      toast.success(ar ? `اتصفّرت ${r.customers} محفظة (${money(r.total)})` : `${r.customers} wallets zeroed (${money(r.total)})`);
      onDone();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  return (
    <Button size="sm" variant={armed ? "destructive" : "outline"} disabled={zero.isPending || total <= 0}
      onClick={() => (armed ? zero.mutate() : setArmed(true))}>
      <Wallet className="me-1 size-4" />
      {armed
        ? ar ? `متأكد؟ صفّر ${money(total)}` : `Sure? Zero ${money(total)}`
        : ar ? "صفّر كل المحافظ" : "Zero all wallets"}
    </Button>
  );
}

/** Restart the cashback target for one customer (customerId) or for every customer. Two taps, no browser dialog. */
function ResetCashbackButton({ customerId, lang, onDone }: { customerId?: string; lang: "ar" | "en"; onDone: () => void }) {
  const ar = lang === "ar";
  const [armed, setArmed] = useState(false);
  useEffect(() => {
    if (!armed) return;
    const timer = setTimeout(() => setArmed(false), 5000);
    return () => clearTimeout(timer);
  }, [armed]);
  const reset = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc("reset_cashback_progress" as never, { _customer_id: customerId ?? null } as never);
      if (error) throw error;
      return Number(data ?? 0);
    },
    onSuccess: (n) => {
      setArmed(false);
      toast.success(ar ? `اتصفّر التارجت (${n} عميل)` : `Target restarted (${n} customers)`);
      onDone();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const label = customerId
    ? armed ? (ar ? "متأكد؟ صفّر" : "Sure? Reset") : (ar ? "صفّر التارجت" : "Reset target")
    : armed ? (ar ? "متأكد؟ صفّر للكل" : "Sure? Reset all") : (ar ? "صفّر التارجت لكل العملاء" : "Reset target for everyone");
  return (
    <Button size="sm" variant={armed ? "destructive" : "outline"} disabled={reset.isPending}
      onClick={() => (armed ? reset.mutate() : setArmed(true))}>
      <RotateCcw className="me-1 size-4" />{label}
    </Button>
  );
}

function WalletHistoryDialog({ customer, onClose, money, lang }: {
  customer: Customer | null; onClose: () => void; money: (v: number) => string; lang: "ar" | "en";
}) {
  const ar = lang === "ar";
  const history = useQuery({
    queryKey: ["wallet-history", customer?.id],
    enabled: Boolean(customer),
    queryFn: async () => {
      const { data, error } = await supabase.from("customer_wallet_transactions")
        .select("id, kind, amount, balance_after, description, created_at")
        .eq("customer_id", customer!.id).order("created_at", { ascending: false }).limit(100);
      if (error) throw error;
      return data ?? [];
    },
  });
  const KIND: Record<string, string> = ar
    ? { earn: "كسب", redeem: "استخدام", refund: "رجوع من مرتجع", adjust: "تعديل يدوي", migration: "تحويل من النقاط" }
    : { earn: "Earned", redeem: "Used", refund: "Refunded", adjust: "Adjustment", migration: "From points" };
  return (
    <Dialog open={Boolean(customer)} onOpenChange={(v) => !v && onClose()}>
      <DialogContent dir={ar ? "rtl" : "ltr"} className="max-w-lg">
        <DialogHeader><DialogTitle>{ar ? `حركات محفظة ${customer?.name ?? ""}` : `${customer?.name ?? ""} — wallet history`}</DialogTitle></DialogHeader>
        {(history.data ?? []).length === 0 ? (
          <p className="py-6 text-center text-sm text-muted-foreground">{ar ? "مفيش حركات لسه" : "No movements yet"}</p>
        ) : (
          <ul className="max-h-96 divide-y overflow-y-auto text-sm">
            {(history.data ?? []).map((h) => (
              <li key={h.id} className="flex items-center justify-between gap-3 py-2">
                <div>
                  <p className="font-medium">{KIND[h.kind] ?? h.kind}</p>
                  <p className="text-xs text-muted-foreground">{formatDateTime(h.created_at, lang)}{h.description ? ` · ${h.description}` : ""}</p>
                </div>
                <div className="text-end tabular-nums">
                  <p className={Number(h.amount) < 0 ? "text-destructive" : "text-success"}>{Number(h.amount) > 0 ? "+" : ""}{money(Number(h.amount))}</p>
                  <p className="text-xs text-muted-foreground">{money(Number(h.balance_after))}</p>
                </div>
              </li>
            ))}
          </ul>
        )}
      </DialogContent>
    </Dialog>
  );
}

function EditCustomerDialog({ customer, onClose, money, lang }: {
  customer: Customer | null; onClose: () => void; money: (v: number) => string; lang: "ar" | "en";
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [delta, setDelta] = useState("");
  const [reason, setReason] = useState("");
  useEffect(() => { setName(customer?.name ?? ""); setPhone(customer?.phone ?? ""); setDelta(""); setReason(""); }, [customer]);

  const save = useMutation({
    mutationFn: async () => {
      if (!customer) return;
      if (name.trim() !== customer.name || phone.trim() !== (customer.phone ?? "")) {
        const { error } = await supabase.rpc("update_customer_details", { _customer_id: customer.id, _name: name.trim(), _phone: phone.trim() });
        if (error) throw error;
      }
      const amount = Number(delta);
      if (amount) {
        const { error } = await supabase.rpc("adjust_customer_wallet", { _customer_id: customer.id, _amount: amount, _reason: reason.trim() });
        if (error) throw error;
      }
    },
    onSuccess: () => {
      toast.success(ar ? "اتحفظ" : "Saved");
      qc.invalidateQueries({ queryKey: ["cashback-customers"] });
      qc.invalidateQueries({ queryKey: ["cashback-liability"] });
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const remove = useMutation({
    mutationFn: async () => {
      if (!customer) return null;
      const { data, error } = await supabase.rpc("delete_customer" as never, { _customer_id: customer.id } as never);
      if (error) throw error;
      return data as unknown as string;
    },
    onSuccess: (mode) => {
      toast.success(
        mode === "archived"
          ? ar ? "العميل ليه فواتير، فاتشال من القوائم وسجله محفوظ" : "Customer has invoices, so they were archived (history kept)"
          : ar ? "تم حذف العميل" : "Customer deleted",
      );
      qc.invalidateQueries({ queryKey: ["cashback-customers"] });
      qc.invalidateQueries({ queryKey: ["cashback-liability"] });
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const [confirmDelete, setConfirmDelete] = useState(false);
  useEffect(() => setConfirmDelete(false), [customer]);
  const amount = Number(delta);
  const valid = name.trim().length > 0 && (!amount || reason.trim().length >= 3);

  return (
    <Dialog open={Boolean(customer)} onOpenChange={(v) => !v && onClose()}>
      <DialogContent dir={ar ? "rtl" : "ltr"}>
        <DialogHeader><DialogTitle>{ar ? "تعديل العميل" : "Edit customer"}</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1"><Label htmlFor="c-name">{ar ? "الاسم" : "Name"}</Label><Input id="c-name" value={name} onChange={(e) => setName(e.target.value)} /></div>
          <div className="space-y-1"><Label htmlFor="c-phone">{ar ? "الموبايل" : "Phone"}</Label><Input id="c-phone" dir="ltr" value={phone} onChange={(e) => setPhone(e.target.value)} /></div>
          <div className="rounded-xl bg-muted/60 p-3 text-sm">{ar ? "الرصيد الحالي" : "Current balance"}: <b className="tabular-nums">{money(Number(customer?.wallet_balance ?? 0))}</b></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="c-delta">{ar ? "زوّد / نقّص (مثلاً 50 أو ‎-20)" : "Add / remove (e.g. 50 or -20)"}</Label>
              <Input id="c-delta" dir="ltr" inputMode="decimal" value={delta} onChange={(e) => setDelta(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="c-reason">{ar ? "السبب" : "Reason"}</Label>
              <Input id="c-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
            </div>
          </div>
        </div>
        <DialogFooter className="gap-2 sm:justify-between">
          {confirmDelete ? (
            <div className="flex items-center gap-2">
              <span className="text-sm text-destructive">{ar ? "متأكد؟" : "Sure?"}</span>
              <Button variant="destructive" size="sm" disabled={remove.isPending} onClick={() => remove.mutate()}>
                {ar ? "أيوه احذف" : "Yes, delete"}
              </Button>
              <Button variant="ghost" size="sm" onClick={() => setConfirmDelete(false)}>{ar ? "لا" : "No"}</Button>
            </div>
          ) : (
            <Button variant="outline" className="border-destructive/40 text-destructive" onClick={() => setConfirmDelete(true)}>
              {ar ? "حذف العميل" : "Delete customer"}
            </Button>
          )}
          <Button disabled={!valid || save.isPending} onClick={() => save.mutate()}>{ar ? "احفظ" : "Save"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function NewCustomerDialog({ open, onOpenChange, lang }: { open: boolean; onOpenChange: (v: boolean) => void; lang: "ar" | "en" }) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const create = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("upsert_customer", { _name: name.trim(), _phone: phone.trim() });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "اتضاف العميل" : "Customer added");
      setName(""); setPhone("");
      qc.invalidateQueries({ queryKey: ["cashback-customers"] });
      onOpenChange(false);
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent dir={ar ? "rtl" : "ltr"}>
        <DialogHeader><DialogTitle>{ar ? "عميل جديد" : "New customer"}</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1"><Label htmlFor="n-name">{ar ? "الاسم" : "Name"}</Label><Input id="n-name" value={name} onChange={(e) => setName(e.target.value)} /></div>
          <div className="space-y-1"><Label htmlFor="n-phone">{ar ? "الموبايل" : "Phone"}</Label><Input id="n-phone" dir="ltr" value={phone} onChange={(e) => setPhone(e.target.value)} /></div>
        </div>
        <DialogFooter><Button disabled={!name.trim() || !phone.trim() || create.isPending} onClick={() => create.mutate()}>{ar ? "أضف" : "Add"}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
