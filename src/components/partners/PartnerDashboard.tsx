import { useQuery } from "@tanstack/react-query";
import { Banknote, Coins, HandCoins, Receipt, ShoppingBag, Truck, Wallet } from "lucide-react";
import { useState } from "react";

import { DateRangeFilter, RANGE_PRESETS, type DateRange } from "@/components/shared/DateRangeFilter";
import { InfoTip } from "@/components/shared/InfoTip";
import { KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import { Skeleton } from "@/components/ui/skeleton";
import { rangeLabel } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney, formatPercent, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import { SectionTitle } from "@/components/shared/SectionTitle";

type Dashboard = {
  from: string;
  to: string;
  partner_name: string;
  share_pct: number;
  gross_sales: number;
  revenue: number;
  net_profit: number;
  my_share_estimate: number;
  my_tab_total: number;
  my_tabs: Array<{ order_number: string; created_at: string; amount: number; open: number }>;
  my_open_advances: number;
  my_balance: number;
  supplier_debts: number;
  shifts: Array<{ shift_id: string; opened_at: string; closed_at: string | null; cashier: string | null; net_sales: number; gross_margin: number; variance: number | null }>;
};

/** The signed-in partner's own dashboard for any date range. */
export function PartnerDashboard() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number | null | undefined) => formatMoney(Number(v ?? 0), currency, lang);
  const [range, setRange] = useState<DateRange>(() => ({ from: RANGE_PRESETS.thisMonth().from, to: RANGE_PRESETS.today().to }));

  const q = useQuery({
    queryKey: ["my-partner-dashboard", range.from, range.to],
    enabled: range.from <= range.to,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("my_partner_dashboard", { _from: range.from, _to: range.to });
      if (error) throw error;
      return data as unknown as Dashboard;
    },
  });
  const d = q.data;

  return (
    <div dir={ar ? "rtl" : "ltr"} className="space-y-5">
      <header className="space-y-1">
        <h1 className="text-2xl font-black">{ar ? `أهلاً ${d?.partner_name ?? ""}` : `Hi ${d?.partner_name ?? ""}`}</h1>
        <p className="text-sm text-muted-foreground">
          {ar ? "ده ملخص المكان ونصيبك في الفترة اللي تختارها." : "The café and your share for the range you pick."}
        </p>
      </header>
      <DateRangeFilter value={range} onChange={setRange} />

      {q.isError && <p className="rounded-xl bg-destructive/10 p-3 text-sm text-destructive">{friendlyError(q.error, lang)}</p>}
      {q.isLoading || !d ? (
        !q.isError && <Skeleton className="h-48 w-full rounded-2xl" />
      ) : (
        <>
          <KpiGrid cols={4} title={ar ? `المكان · ${rangeLabel(d.from, d.to, lang)}` : `The café · ${rangeLabel(d.from, d.to, lang)}`}>
            <KpiCard label={ar ? "إجمالي المبيعات" : "Total sales"} value={money(d.gross_sales)} icon={<Receipt className="size-4" />}
              formula={ar ? "سعر كل الأصناف اللي اتباعت قبل العروض والخصومات." : "Every item sold at full price, before offers and discounts."} />
            <KpiCard label={ar ? "صافي الإيراد" : "Net revenue"} value={money(d.revenue)} tone="brand" icon={<Coins className="size-4" />}
              formula={ar ? "المبيعات بعد العروض والخصومات والمرتجعات." : "Sales after offers, discounts and refunds."} />
            <KpiCard label={d.net_profit < 0 ? (ar ? "صافي الخسارة" : "Net loss") : ar ? "صافي الربح" : "Net profit"} value={money(Math.abs(d.net_profit))}
              tone={d.net_profit < 0 ? "bad" : "good"} icon={<Banknote className="size-4" />}
              formula={ar ? "بعد الخامات والهالك والمصاريف والرواتب — نفس رقم قائمة الدخل." : "After COGS, waste, expenses and payroll — the P&L figure."} />
            <KpiCard label={ar ? "ديون الموردين (كلها)" : "Supplier debts (all)"} value={money(d.supplier_debts)} tone={d.supplier_debts > 0 ? "warn" : undefined}
              icon={<Truck className="size-4" />}
              formula={ar ? "فواتير الموردين اللي لسه متدفعتش بالكامل لحد النهارده." : "Supplier invoices still unpaid as of today."} />
          </KpiGrid>

          <KpiGrid cols={4} title={ar ? "حسابك" : "Your account"}>
            <KpiCard label={ar ? `نصيبك التقديري (${formatPercent(d.share_pct, lang)})` : `Your estimated share (${formatPercent(d.share_pct, lang)})`}
              value={money(d.my_share_estimate)} tone="good" icon={<HandCoins className="size-4" />}
              formula={ar ? "صافي الربح × نسبتك. ده تقدير؛ الرقم النهائي بيتحدد يوم التوزيع بعد رواتب الإدارة والاحتياطي وصندوق التطوير." : "Net profit × your share. Final figure is set at payout after management pay, reserve and the fund."} />
            <KpiCard label={ar ? "مشترياتك على الحساب" : "Your tab purchases"} value={money(d.my_tab_total)} icon={<ShoppingBag className="size-4" />}
              hint={`${d.my_tabs.length} ${ar ? "طلب" : "orders"}`}
              formula={ar ? "اللي اشتريته على حسابك في الفترة دي. بيتخصم من نصيبك أوتوماتيك يوم التوزيع." : "What you bought on your tab in this range; deducted from your share at payout."} />
            <KpiCard label={ar ? "سلف عليك" : "Your open advances"} value={money(d.my_open_advances)} tone={d.my_open_advances > 0 ? "warn" : undefined}
              icon={<Wallet className="size-4" />}
              formula={ar ? "فلوس أخدتها قبل التوزيع ولسه متخصمتش." : "Money taken before a payout, not yet recovered."} />
            <KpiCard label={ar ? "رصيدك" : "Your balance"} value={money(d.my_balance)} tone={d.my_balance < 0 ? "bad" : "good"}
              formula={ar ? "أرباحك اللي اتوزعت − اللي صرفته − السلف المفتوحة." : "Distributed profit − what you withdrew − open advances."} />
          </KpiGrid>

          <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm">
            <div className="mb-3 flex items-center gap-1.5">
              <SectionTitle>{ar ? "الورديات" : "Shifts"}</SectionTitle>
              <InfoTip>{ar ? "كل وردية في الفترة: صافي مبيعاتها ومجمل ربحها وفرق الدرج لو فيه." : "Each shift in the range: net sales, gross margin and drawer difference."}</InfoTip>
            </div>
            {d.shifts.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">{ar ? "مفيش ورديات في الفترة دي" : "No shifts in this range"}</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[520px] text-sm">
                  <thead className="text-xs text-muted-foreground">
                    <tr className="border-b">
                      <th className="py-2 text-start font-medium">{ar ? "الوردية" : "Shift"}</th>
                      <th className="py-2 text-start font-medium">{ar ? "الكاشير" : "Cashier"}</th>
                      <th className="py-2 text-end font-medium">{ar ? "صافي المبيعات" : "Net sales"}</th>
                      <th className="py-2 text-end font-medium">{ar ? "مجمل الربح" : "Gross margin"}</th>
                      <th className="py-2 text-end font-medium">{ar ? "فرق الدرج" : "Drawer diff."}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {d.shifts.map((s) => (
                      <tr key={s.shift_id} className="border-b last:border-0">
                        <td className="py-2">{formatDateTime(s.opened_at, lang)}{!s.closed_at && <span className="ms-1 text-xs text-primary">{ar ? "(مفتوحة)" : "(open)"}</span>}</td>
                        <td className="py-2">{s.cashier ?? "—"}</td>
                        <td className="py-2 text-end tabular-nums">{money(s.net_sales)}</td>
                        <td className={cn("py-2 text-end tabular-nums", s.gross_margin < 0 && "text-destructive")}>{money(s.gross_margin)}</td>
                        <td className={cn("py-2 text-end tabular-nums", (s.variance ?? 0) < 0 && "text-destructive")}>{s.variance === null ? "—" : money(s.variance)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {d.my_tabs.length > 0 && (
            <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm">
              <SectionTitle className="mb-3">{ar ? "مشترياتك على الحساب" : "Your tab purchases"}</SectionTitle>
              <ul className="divide-y text-sm">
                {d.my_tabs.map((t) => (
                  <li key={`${t.order_number}-${t.created_at}`} className="flex items-center justify-between gap-3 py-2">
                    <span>#{t.order_number} · {formatDateTime(t.created_at, lang)}</span>
                    <span className="tabular-nums">
                      {money(t.amount)}
                      {t.open > 0 && <span className="ms-2 text-xs text-amber-600">{ar ? "لسه" : "open"} {money(t.open)}</span>}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </div>
  );
}
