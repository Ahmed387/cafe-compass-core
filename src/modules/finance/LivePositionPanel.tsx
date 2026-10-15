import { useQuery } from "@tanstack/react-query";

import { KpiCard } from "@/components/shared/KpiCard";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Drawer = {
  shift_id: string;
  cashier: string | null;
  opened_at: string;
  opening_cash: number;
  cash_in: number;
  cash_refunds: number;
  drawer_expenses: number;
  drawer_now: number;
  orders: number;
  tenders: Record<string, number>;
};
type Account = { key: string; name: string; balance: number };
type Live = {
  as_of: string;
  days_passed: number;
  days_in_month: number;
  drawers: Drawer[];
  accounts: Account[];
  cash_total: number;
  can_profit: boolean;
  today: null | {
    orders: number;
    revenue: number;
    cogs: number;
    gross_profit: number;
    expenses: number;
    net_before_salaries: number;
  };
  month: null | {
    orders: number;
    revenue: number;
    cogs: number;
    gross_profit: number;
    expenses: number;
    payroll_recorded: number;
    salaries_accrued: number;
    salaries_full_month: number;
    other_losses: number;
    net_profit: number;
  };
};

const TENDER_AR: Record<string, string> = {
  cash: "كاش",
  instapay: "إنستاباي",
  wallet: "محفظة",
  visa: "فيزا",
  partner_tab: "على حساب شريك",
};

/**
 * "Where do we stand right now": cash in each open drawer, every treasury account,
 * and today's / this month's profit — one server call (live_position), refreshed
 * every minute, same numbers as the P&L page.
 */
export function LivePositionPanel() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number | null | undefined) => formatMoney(Number(v ?? 0), currency, lang);

  const live = useQuery({
    queryKey: ["live-position"],
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("live_position" as never);
      if (error) throw error;
      return data as unknown as Live;
    },
  });
  const d = live.data;
  if (!d) return null;

  const drawerNow = d.drawers.reduce((s, x) => s + Number(x.drawer_now), 0);
  const row = (label: string, value: string, strong = false) => (
    <div className="flex justify-between gap-3 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className={strong ? "font-semibold tabular-nums" : "tabular-nums"}>{value}</span>
    </div>
  );

  return (
    <section className="space-y-3">
      <p className="text-xs font-medium text-muted-foreground">
        {ar ? "الوضع دلوقتي" : "Right now"} · {formatDateTime(d.as_of, lang)}
        {ar ? " · بيتحدّث كل دقيقة" : " · refreshes every minute"}
      </p>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <KpiCard
          size="master"
          tone="brand"
          label={ar ? "في الدرج دلوقتي" : "In the drawer now"}
          value={d.drawers.length ? money(drawerNow) : ar ? "مفيش وردية" : "No open shift"}
          hint={d.drawers.map((x) => x.cashier ?? "—").join("، ")}
          formula={
            ar
              ? "فكّة البداية + الكاش اللي اتدفع − المرتجعات الكاش − مصروفات الدرج."
              : "Opening float + cash taken − cash refunds − drawer expenses."
          }
          details={
            <div className="space-y-4">
              {d.drawers.map((x) => (
                <div key={x.shift_id} className="space-y-1 rounded-lg border border-border p-3">
                  <p className="font-medium">
                    {x.cashier ?? "—"} · {ar ? "من" : "since"} {formatDateTime(x.opened_at, lang)}
                  </p>
                  {row(ar ? "فكّة البداية" : "Opening float", money(x.opening_cash))}
                  {row(ar ? "+ كاش اتدفع" : "+ Cash taken", money(x.cash_in))}
                  {row(ar ? "− مرتجعات كاش" : "− Cash refunds", money(x.cash_refunds))}
                  {row(ar ? "− مصروفات من الدرج" : "− Drawer expenses", money(x.drawer_expenses))}
                  {row(
                    ar ? "= المفروض في الدرج" : "= Should be in drawer",
                    money(x.drawer_now),
                    true,
                  )}
                  <p className="pt-1 text-xs text-muted-foreground">
                    {x.orders} {ar ? "فاتورة" : "invoices"} ·{" "}
                    {Object.entries(x.tenders)
                      .filter(([k]) => k !== "cash")
                      .map(([k, v]) => `${ar ? (TENDER_AR[k] ?? k) : k}: ${money(v)}`)
                      .join(" · ") || (ar ? "كله كاش" : "all cash")}
                  </p>
                </div>
              ))}
            </div>
          }
        />
        <KpiCard
          size="master"
          label={ar ? "كل الفلوس" : "All money"}
          value={money(d.cash_total)}
          hint={ar ? "الخزنة والبنك والمحافظ والدرج" : "Safe, bank, wallets and drawer"}
          formula={
            ar
              ? "رصيد كل حساب في الخزينة + اللي في الأدراج المفتوحة."
              : "Every treasury account balance + open drawers."
          }
          details={
            <div className="space-y-2">
              {d.accounts.map((a) => (
                <div key={a.key}>{row(a.name, money(a.balance))}</div>
              ))}
              {d.drawers.length > 0 &&
                row(ar ? "الأدراج المفتوحة" : "Open drawers", money(drawerNow))}
            </div>
          }
        />
        {d.today && (
          <KpiCard
            size="master"
            label={ar ? "مبيعات النهارده" : "Sales today"}
            value={money(d.today.revenue)}
            hint={`${d.today.orders} ${ar ? "فاتورة" : "invoices"}`}
            formula={
              ar
                ? "صافي المبيعات بعد الخصومات والمرتجعات."
                : "Net sales after discounts and refunds."
            }
          />
        )}
        {d.today && (
          <KpiCard
            size="master"
            tone={d.today.net_before_salaries < 0 ? "bad" : "good"}
            label={ar ? "ربح النهارده" : "Profit today"}
            value={money(d.today.net_before_salaries)}
            hint={ar ? "قبل المرتبات" : "before salaries"}
            formula={
              ar
                ? "المبيعات − تكلفة الخامات − الهالك − مصروفات النهارده."
                : "Sales − ingredient cost − waste − today's expenses."
            }
            details={
              <div className="space-y-2">
                {row(ar ? "المبيعات" : "Sales", money(d.today.revenue))}
                {row(
                  ar ? "− تكلفة الخامات والهالك" : "− Ingredients & waste",
                  money(Number(d.today.revenue) - Number(d.today.gross_profit)),
                )}
                {row(ar ? "− المصروفات" : "− Expenses", money(d.today.expenses))}
                {row(ar ? "= الربح" : "= Profit", money(d.today.net_before_salaries), true)}
              </div>
            }
          />
        )}
      </div>

      {d.month && (
        <>
          <p className="pt-2 text-xs font-medium text-muted-foreground">
            {ar
              ? `من أول الشهر لحد النهارده (يوم ${d.days_passed} من ${d.days_in_month})`
              : `Month to date (day ${d.days_passed} of ${d.days_in_month})`}
          </p>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <KpiCard
              label={ar ? "المبيعات" : "Sales"}
              value={money(d.month.revenue)}
              hint={`${d.month.orders} ${ar ? "فاتورة" : "invoices"}`}
            />
            <KpiCard
              label={ar ? "الخامات والهالك" : "Ingredients & waste"}
              value={money(Number(d.month.revenue) - Number(d.month.gross_profit))}
              hint={`${Math.round(((Number(d.month.revenue) - Number(d.month.gross_profit)) / Math.max(1, Number(d.month.revenue))) * 100)}% ${ar ? "من المبيعات" : "of sales"}`}
            />
            <KpiCard
              label={ar ? "المصروفات والمرتبات" : "Expenses & salaries"}
              value={money(
                Number(d.month.expenses) +
                  Number(d.month.payroll_recorded) +
                  Number(d.month.salaries_accrued),
              )}
              formula={
                ar
                  ? "المصروفات المعتمدة + المرتبات المصروفة + نصيب الأيام اللي عدّت من مرتبات الشهر اللي لسه متصرفتش."
                  : "Approved expenses + salaries paid + this month's unpaid salaries for the days already worked."
              }
              details={
                <div className="space-y-2">
                  {row(ar ? "المصروفات" : "Expenses", money(d.month.expenses))}
                  {row(ar ? "مرتبات اتصرفت" : "Salaries paid", money(d.month.payroll_recorded))}
                  {row(
                    ar
                      ? `مرتبات مستحقة لحد النهارده (${d.days_passed}/${d.days_in_month} يوم)`
                      : `Salaries accrued to date (${d.days_passed}/${d.days_in_month} days)`,
                    money(d.month.salaries_accrued),
                  )}
                  {row(
                    ar ? "مرتبات الشهر كله" : "Full month salaries",
                    money(d.month.salaries_full_month),
                  )}
                </div>
              }
            />
            <KpiCard
              size="master"
              tone={d.month.net_profit < 0 ? "bad" : "good"}
              label={ar ? "صافي الربح لحد دلوقتي" : "Net profit so far"}
              value={money(d.month.net_profit)}
              formula={
                ar
                  ? "المبيعات − الخامات والهالك − المصروفات − المرتبات (المصروفة + المستحقة لحد النهارده) − عجز الدرج."
                  : "Sales − ingredients & waste − expenses − salaries (paid + accrued) − drawer shortages."
              }
            />
          </div>
        </>
      )}
    </section>
  );
}
