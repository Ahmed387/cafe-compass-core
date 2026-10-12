import { FinancePage } from "@/modules/finance/FinancePage";
import { TreasuryPage } from "@/modules/finance/TreasuryPage";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useI18n } from "@/lib/i18n";
import { FinanceKpiStrip } from "@/modules/finance/FinanceKpiStrip";

/**
 * Sensitive financials: master safe ledger and profit & payouts (payroll lives on the HR page).
 * Operational expenses live on their own page (/expenses) so managers never
 * reach salaries or equity distributions.
 */
export function MoneyHub() {
  const { t } = useI18n();
  return (
    <>
    <FinanceKpiStrip />
    <Tabs defaultValue="treasury" className="animate-fade-in">
      <TabsList>
        <TabsTrigger value="treasury">{t("money.tab.treasury")}</TabsTrigger>
        <TabsTrigger value="profit">{t("fin.profit")}</TabsTrigger>
      </TabsList>
      <TabsContent value="treasury" className="mt-4">
        <TreasuryPage />
      </TabsContent>
      <TabsContent value="profit" className="mt-4">
        <FinancePage sections={["profit"]} bare />
      </TabsContent>
    </Tabs>
    </>
  );
}
