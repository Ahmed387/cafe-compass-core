import { useQuery } from "@tanstack/react-query";

import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, formatPercent } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type OwnerStatement = {
  partner: {
    id: string;
    name: string;
    tier: "silent" | "manager" | "manager_employee";
    share: number | null;
    capital: number;
    total_capital: number;
    unpaid_tabs: number;
    unpaid_count: number;
  } | null;
  compensation: {
    mode: "fixed" | "percent" | "hybrid";
    fixed: number;
    percent: number;
    basis: "profit" | "sales";
  } | null;
  month_sales: number;
  profit: {
    has_period: boolean;
    period_start: string | null;
    period_end: string | null;
    company_net_profit: number;
    my_percentage: number;
    my_profit: number;
    my_capital: number;
    lifetime_profit: number;
  } | null;
};

/**
 * Strictly personal owner card: every number comes from `my_owner_statement()`,
 * which resolves the signed-in profile server-side, so one owner can never read
 * another owner's equity, tabs or managerial pay.
 */
export function OwnerStatementPanel() {
  const { lang } = useI18n();
  const { me } = useAuth();
  const ar = lang === "ar";
  const currency = me?.company?.currency ?? "EGP";

  const statement = useQuery({
    queryKey: ["my-owner-statement", me?.profile.id ?? null],
    enabled: Boolean(me),
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("my_owner_statement");
      if (error) throw error;
      return (data ?? null) as unknown as OwnerStatement | null;
    },
  });

  const row = statement.data;
  if (!row || (!row.partner && !row.compensation)) return null;

  const tierLabel = (tier: string) =>
    tier === "silent"
      ? ar
        ? "شريك مستثمر"
        : "Silent investor"
      : tier === "manager"
        ? ar
          ? "شريك ومدير"
          : "Partner & manager"
        : ar
          ? "شريك ومدير وموظف"
          : "Partner, manager & employee";

  const equityPercent =
    row.partner && row.partner.total_capital > 0
      ? (row.partner.capital / row.partner.total_capital) * 100
      : (row.partner?.share ?? 0);

  const line = (label: string, value: string, strong = false) => (
    <div className="flex items-center justify-between gap-3 border-b border-border/60 py-2 last:border-0">
      <span className="text-muted-foreground">{label}</span>
      <span className={strong ? "text-lg font-black tabular-nums text-primary" : "font-bold tabular-nums"}>
        {value}
      </span>
    </div>
  );

  return (
    <div className="stagger mt-6 grid gap-4 lg:grid-cols-2">
      {row.partner && (
        <Card>
          <CardHeader className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2">
            <CardTitle className="truncate text-base">
              {ar ? "ملف الشريك الشخصي" : "My owner profile"}
            </CardTitle>
            <Badge variant="secondary">{tierLabel(row.partner.tier)}</Badge>
          </CardHeader>
          <CardContent className="text-sm">
            {line(ar ? "رأس مالي المسجل" : "My registered capital", formatMoney(row.partner.capital, currency, lang))}
            {line(ar ? "نسبة الملكية" : "Equity share", formatPercent(equityPercent, lang))}
            {line(
              ar ? "فواتيري غير المسددة" : "My unpaid tabs",
              `${formatMoney(row.partner.unpaid_tabs, currency, lang)} · ${row.partner.unpaid_count}`,
            )}
            <p className="pt-2 text-xs text-muted-foreground">
              {ar
                ? "أرقامك الشخصية فقط — لا تظهر لك بيانات باقي الشركاء."
                : "Your personal figures only — other owners' data is never shown."}
            </p>
          </CardContent>
        </Card>
      )}

      {row.profit && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              {ar ? "أرباحي الموزعة" : "My distributed profit"}
              {row.profit.period_start && row.profit.period_end
                ? ` · ${formatDate(row.profit.period_start, lang)} — ${formatDate(row.profit.period_end, lang)}`
                : ""}
            </CardTitle>
          </CardHeader>
          <CardContent className="text-sm">
            {row.profit.has_period ? (
              <>
                {line(ar ? "نسبتي في التوزيع" : "My distribution share", formatPercent(row.profit.my_percentage, lang))}
                {line(ar ? "حصتي من ربح الفترة" : "My profit this period", formatMoney(row.profit.my_profit, currency, lang), true)}
                {line(
                  ar ? "إجمالي ما وُزّع لي" : "Lifetime distributed to me",
                  formatMoney(row.profit.lifetime_profit, currency, lang),
                )}
              </>
            ) : (
              <p className="text-muted-foreground">
                {ar
                  ? "لا يوجد توزيع أرباح لفترة مقفلة حتى الآن."
                  : "No profit distribution for a closed period yet."}
              </p>
            )}
          </CardContent>
        </Card>
      )}

      {row.compensation && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{ar ? "تعويضي الإداري" : "My managerial pay"}</CardTitle>
          </CardHeader>
          <CardContent className="text-sm">
            {row.compensation.mode !== "percent" &&
              line(ar ? "راتب شهري ثابت" : "Fixed monthly", formatMoney(row.compensation.fixed, currency, lang))}
            {row.compensation.mode !== "fixed" && (
              <>
                {line(
                  ar ? "نسبة" : "Percent",
                  `${formatPercent(row.compensation.percent, lang)} · ${
                    row.compensation.basis === "profit"
                      ? ar
                        ? "من صافي الربح"
                        : "of net profit"
                      : ar
                        ? "من المبيعات"
                        : "of sales"
                  }`,
                )}
                {row.compensation.basis === "sales" &&
                  line(
                    ar ? "تقدير هذا الشهر" : "This month estimate",
                    formatMoney((row.month_sales * row.compensation.percent) / 100, currency, lang),
                    true,
                  )}
              </>
            )}
            <p className="pt-2 text-xs text-muted-foreground">
              {ar
                ? "التعويض الإداري مصروف تشغيلي يُخصم قبل صافي الربح."
                : "Managerial pay is an operating cost deducted before net profit."}
            </p>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
