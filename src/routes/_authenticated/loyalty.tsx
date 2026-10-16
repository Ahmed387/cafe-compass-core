import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Coins, Gift, Save, Target, UserPlus, Wallet } from "lucide-react";
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
import { printCustomerCard } from "@/lib/loyalty";
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
  total_spent: number;
  visits: number;
  /** Visit stamps toward the next free drink. */
  points_balance: number | null;
  last_visit_at: string | null;
};

type CashbackConfig = { enabled: boolean; target_amount: number; reward_amount: number };

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
      return data as unknown as CashbackConfig;
    },
  });

  const customers = useQuery({
    queryKey: ["cashback-customers", search, page],
    enabled: canView,
    queryFn: async () => {
      let query = supabase
        .from("customers")
        .select("id, code, name, phone, barcode, wallet_balance, cashback_progress, total_spent, visits, points_balance, last_visit_at", { count: "exact" })
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

  const printCard = async (row: Customer) => {
    const ok = await printCustomerCard({
      companyName: me?.company?.name ?? "20s Coffee",
      name: row.name,
      code: row.code,
      barcode: row.barcode,
      wallet: Number(row.wallet_balance),
      currency,
      lang,
      url: `${window.location.origin}/c/${row.barcode}`,
      labels: {
        title: ar ? "كارت العميل" : "Customer card",
        hint: ar ? "اعرض الكارت عند الكاشير عشان تجمع كاش باك" : "Show this card at the till to collect cashback",
        wallet: ar ? "رصيد الكاش باك" : "Cashback balance",
        id: ar ? "رقم العميل" : "ID",
      },
    });
    if (!ok) toast.error(t("orders.printBlocked"));
  };

  const visitCfg = useQuery({
    queryKey: ["visit-rewards-config", me?.profile.company_id],
    enabled: Boolean(me?.profile.company_id),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("visit_rewards_config" as never, { _company: me!.profile.company_id } as never);
      if (error) throw error;
      return (data ?? { enabled: false, visits_per_reward: 10 }) as VisitRewardConfig;
    },
  });
  const visitsNeeded = Number(visitCfg.data?.visits_per_reward ?? 10);

  return (
    <div className="space-y-5">
      <PageHeader
        title={ar ? "العملاء والكاش باك" : "Customers & cashback"}
        description={ar ? "العميل بيجمع كاش باك في محفظته كل ما يوصل لمبلغ معين، ويستخدمه في فواتيره الجاية." : "Customers earn cashback into a wallet every time they reach a spend target, and use it on later bills."}
        action={canView ? <Button onClick={() => setNewOpen(true)}><UserPlus className="me-1 size-4" />{ar ? "عميل جديد" : "New customer"}</Button> : undefined}
      />

      <KpiGrid cols={3}>
        <KpiCard label={ar ? "القاعدة الحالية" : "Current rule"} icon={<Target className="size-4" />}
          value={cfg ? (cfg.enabled ? (ar ? `كل ${money(cfg.target_amount)} ← ${money(cfg.reward_amount)}` : `Every ${money(cfg.target_amount)} → ${money(cfg.reward_amount)}`) : ar ? "متوقف" : "Off") : "—"}
          tone={cfg?.enabled ? "good" : undefined}
          formula={ar ? "العميل كل ما مشترياته توصل للمبلغ ده، بيتحط في محفظته الكاش باك. والباقي بيتراكم للمرة الجاية." : "Every time spend reaches the target, the reward goes into the wallet; the rest keeps accumulating."} />
        <KpiCard label={ar ? "فلوس في محافظ العملاء" : "Owed in customer wallets"} icon={<Wallet className="size-4" />}
          value={money(liability.data)} tone="warn"
          formula={ar ? "مجموع أرصدة الكاش باك اللي العملاء لسه ماصرفوهاش — ده التزام على المكان لحد ما يستخدموه." : "Cashback customers haven't spent yet — a liability until used."} />
        <KpiCard label={ar ? "عدد العملاء" : "Customers"} icon={<Gift className="size-4" />} value={customers.data?.total ?? "—"} />
      </KpiGrid>

      {isSuperAdmin && cfg && <CashbackRuleCard config={cfg} lang={lang} money={money} onSaved={() => qc.invalidateQueries({ queryKey: ["cashback-settings"] })} />}
      {isSuperAdmin && visitCfg.data && <VisitRewardCard config={visitCfg.data} lang={lang} onSaved={() => qc.invalidateQueries({ queryKey: ["visit-rewards-config"] })} />}

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
                  <TableHead className="text-center">{ar ? "للمشروب المجاني" : "Free drink"}</TableHead>
                  <TableHead className="text-end">{t("common.actions")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => {
                  const target = Number(cfg?.target_amount ?? 0);
                  const progress = Math.max(Number(row.cashback_progress), 0);
                  return (
                    <TableRow key={row.id}>
                      <TableCell className="font-medium">{row.name}<span className="block font-mono text-xs text-muted-foreground">{row.code}</span></TableCell>
                      <TableCell>{row.phone ?? "—"}</TableCell>
                      <TableCell className="text-end"><Badge variant="secondary" className="tabular-nums">{money(row.wallet_balance)}</Badge></TableCell>
                      <TableCell>
                        {cfg?.enabled && target > 0 ? (
                          <div className="space-y-1">
                            <Progress value={Math.min(progress / target, 1) * 100} className="h-1.5" />
                            <p className="text-xs tabular-nums text-muted-foreground">{ar ? "فاضل" : "Left"} {money(Math.max(target - progress, 0))}</p>
                          </div>
                        ) : <span className="text-xs text-muted-foreground">—</span>}
                      </TableCell>
                      <TableCell className="text-center tabular-nums">
                        {visitCfg.data?.enabled ? (
                          Number(row.points_balance ?? 0) >= visitsNeeded ? (
                            <Badge className="bg-success/15 text-success">{ar ? "مستحق" : "Ready"}</Badge>
                          ) : (
                            <span>{Number(row.points_balance ?? 0)}/{visitsNeeded}</span>
                          )
                        ) : (
                          <span className="text-xs text-muted-foreground">—</span>
                        )}
                        <span className="block text-[10px] text-muted-foreground">{ar ? `${row.visits} زيارة كلها` : `${row.visits} visits total`}</span>
                      </TableCell>
                      <TableCell className="space-x-2 whitespace-nowrap text-end">
                        <Button size="sm" variant="secondary" onClick={() => setHistoryFor(row)}>{ar ? "الحركات" : "History"}</Button>
                        <Button size="sm" variant="outline" onClick={() => printCard(row)}>{ar ? "اطبع الكارت" : "Print card"}</Button>
                        {isSuperAdmin && <Button size="sm" variant="outline" onClick={() => setEditFor(row)}>{ar ? "تعديل" : "Edit"}</Button>}
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

function CashbackRuleCard({ config, lang, money, onSaved }: {
  config: CashbackConfig; lang: "ar" | "en"; money: (v: number) => string; onSaved: () => void;
}) {
  const ar = lang === "ar";
  const [enabled, setEnabled] = useState(config.enabled);
  const [target, setTarget] = useState(String(config.target_amount));
  const [reward, setReward] = useState(String(config.reward_amount));
  useEffect(() => { setEnabled(config.enabled); setTarget(String(config.target_amount)); setReward(String(config.reward_amount)); }, [config]);

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("set_cashback_settings", { _enabled: enabled, _target_amount: Number(target), _reward_amount: Number(reward) });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "اتحفظت قاعدة الكاش باك" : "Cashback rule saved"); onSaved(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const t = Number(target), r = Number(reward);
  const valid = t > 0 && r > 0 && r < t;

  return (
    <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm sm:p-5">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-1.5">
          <SectionTitle icon={Coins}>{ar ? "قاعدة الكاش باك" : "Cashback rule"}</SectionTitle>
          <InfoTip title={ar ? "ليه الكاش باك؟" : "Why cashback?"}>
            {ar
              ? "بيشجع العميل يرجع تاني: كل ما يصرف المبلغ اللي تحدده، بياخد مبلغ ثابت في محفظته يستخدمه في أي فاتورة جاية. أوضح من النقاط وأسهل للكاشير."
              : "Brings customers back: each time they spend your target, a fixed amount lands in their wallet for any later bill. Simpler than points."}
          </InfoTip>
        </div>
        <label className="flex items-center gap-2 text-sm">{ar ? "مفعّل" : "Enabled"}<Switch checked={enabled} onCheckedChange={setEnabled} /></label>
      </div>
      <div className="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
        <div className="space-y-1">
          <Label htmlFor="cb-target">{ar ? "كل ما العميل يصرف" : "Every time the customer spends"}</Label>
          <Input id="cb-target" inputMode="decimal" value={target} onChange={(e) => setTarget(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="cb-reward">{ar ? "ياخد في محفظته" : "They get in their wallet"}</Label>
          <Input id="cb-reward" inputMode="decimal" value={reward} onChange={(e) => setReward(e.target.value)} />
        </div>
        <Button disabled={!valid || save.isPending} onClick={() => save.mutate()}><Save className="me-1 size-4" />{ar ? "احفظ" : "Save"}</Button>
      </div>
      <p className="mt-3 text-xs text-muted-foreground">
        {valid
          ? ar ? `يعني كاش باك ${((r / t) * 100).toFixed(1)}٪ من المشتريات. مثال: عميل صرف ${money(t * 2.5)} ← ياخد ${money(r * 2)} والباقي ${money(t / 2)} بيتراكم للمرة الجاية.`
               : `That's ${((r / t) * 100).toFixed(1)}% back. E.g. spending ${money(t * 2.5)} → ${money(r * 2)} in the wallet, ${money(t / 2)} carries over.`
          : ar ? "المكافأة لازم تكون أقل من مبلغ الهدف." : "The reward must be smaller than the target."}
      </p>
    </section>
  );
}

type VisitRewardConfig = { enabled: boolean; visits_per_reward: number };

function VisitRewardCard({ config, lang, onSaved }: { config: VisitRewardConfig; lang: "ar" | "en"; onSaved: () => void }) {
  const ar = lang === "ar";
  const [enabled, setEnabled] = useState(config.enabled);
  const [visits, setVisits] = useState(String(config.visits_per_reward));
  useEffect(() => { setEnabled(config.enabled); setVisits(String(config.visits_per_reward)); }, [config]);
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("set_visit_rewards" as never, { _enabled: enabled, _visits_per_reward: Number(visits) } as never);
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "اتحفظت مكافأة الزيارات" : "Visit reward saved"); onSaved(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const n = Number(visits);
  const valid = Number.isInteger(n) && n >= 2 && n <= 100;
  return (
    <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm sm:p-5">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <SectionTitle icon={Gift}>{ar ? "مكافأة الزيارات" : "Visit reward"}</SectionTitle>
        <label className="flex items-center gap-2 text-sm">{ar ? "مفعّل" : "Enabled"}<Switch checked={enabled} onCheckedChange={setEnabled} /></label>
      </div>
      <div className="grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
        <div className="space-y-1">
          <Label htmlFor="vr-visits">{ar ? "كل كام زيارة = مشروب مجاني" : "Visits per free drink"}</Label>
          <Input id="vr-visits" inputMode="numeric" value={visits} onChange={(e) => setVisits(e.target.value)} />
        </div>
        <Button disabled={!valid || save.isPending} onClick={() => save.mutate()}><Save className="me-1 size-4" />{ar ? "احفظ" : "Save"}</Button>
      </div>
      <p className="mt-3 text-xs text-muted-foreground">
        {ar
          ? "الزيارة بتتحسب مرة واحدة في اليوم مهما العميل طلب. لما يكمّل العدد، الكاشير بيشوف «اجعله مجاني» جنب المشروبات ويختار واحد. الكاش باك شغال عادي جنبها."
          : "A visit counts once a day however many orders. When reached, the cashier sees “Make it free” on drinks and picks one. Cashback keeps working alongside."}
      </p>
    </section>
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
