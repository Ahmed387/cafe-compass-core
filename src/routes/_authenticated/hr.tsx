import { ManagerPercentPayLines } from "@/modules/finance/ManagerPercentPayLines";
import { createFileRoute } from "@tanstack/react-router";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { UsersPage } from "@/modules/governance/UsersPage";
import { AttendancePage } from "@/modules/governance/AttendancePage";
import { UserCog, Wallet as WalletIcon, Clock } from "lucide-react";
import { z } from "zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { EmployeeDrawer, JOB_TITLES, type HrRow } from "@/components/hr/EmployeeDrawer";
import { matches, SmartFilterBar } from "@/modules/shell/SmartFilterBar";
import { KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import { businessMonth, monthBounds } from "@/core/finance/business-dates";

export const Route = createFileRoute("/_authenticated/hr")({
  head: () => ({
    meta: [
      { title: "Team & HR management — 20s Coffee" },
      {
        name: "description",
        content: "Employee files, hire dates, prorated salaries, hours, penalties, bonuses and net pay.",
      },
      { property: "og:title", content: "HR & payroll — 20s Coffee" },
      {
        property: "og:description",
        content: "Monthly payroll with prorated salary, worked hours, penalties and bonuses.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  validateSearch: (s) => z.object({ tab: z.enum(["team", "attendance", "payroll"]).optional() }).parse(s),
  component: TeamHrPage,
});

function TeamHrPage() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { can } = useAuth();
  const { tab } = Route.useSearch();
  const navigate = Route.useNavigate();
  const team = can("users.view");
  const pay = can("payroll.view");
  const first = team ? "team" : "payroll";
  const value = tab && (tab === "payroll" ? pay : team) ? tab : first;
  const trig = "gap-2 rounded-full px-4 data-[state=active]:shadow-sm";
  return (
    <div className="animate-fade-in space-y-4">
      <PageHeader
        title={ar ? "إدارة الفريق والموارد البشرية" : "Team & HR management"}
        description={ar ? "الحسابات والأدوار والحضور، والرواتب الثابتة ورواتب الإدارة وصرفها — في مكان واحد" : "Accounts, roles and attendance, plus salaries, manager pay and payouts — in one place"}
      />
      <Tabs value={value} onValueChange={(v) => navigate({ search: { tab: v as "team" }, replace: true })}>
        <TabsList className="h-auto flex-wrap gap-1 rounded-2xl bg-muted p-1">
          {team && <TabsTrigger value="team" className={trig}><UserCog className="size-4" />{ar ? "الفريق والصلاحيات" : "Team & access"}</TabsTrigger>}
          {team && <TabsTrigger value="attendance" className={trig}><Clock className="size-4" />{ar ? "الحضور والسلف" : "Attendance"}</TabsTrigger>}
          {pay && <TabsTrigger value="payroll" className={trig}><WalletIcon className="size-4" />{ar ? "الرواتب والمستحقات" : "Payroll & salaries"}</TabsTrigger>}
        </TabsList>
        {team && <TabsContent value="team" className="mt-4"><UsersPage /></TabsContent>}
        {team && <TabsContent value="attendance" className="mt-4"><AttendancePage /></TabsContent>}
        {pay && <TabsContent value="payroll" className="mt-4"><HrPage /></TabsContent>}
      </Tabs>
      {!team && !pay && <NoPermission message={ar ? "لا تملك صلاحية لهذه الصفحة" : "No access"} />}
    </div>
  );
}

type Row = HrRow;


function HrPage() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { can, me } = useAuth();
  const qc = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  const canView = can("payroll.view");
  const manage = can("payroll.manage");
  const money = (v: number) => formatMoney(Number(v), currency, lang);

  const [month, setMonth] = useState(() => businessMonth());
  const { start, end } = monthBounds(month);

  const preview = useQuery({
    queryKey: ["hr-preview", start, end],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("hr_payroll_preview", {
        _period_start: start,
        _period_end: end,
      });
      if (error) throw error;
      return (data ?? []) as Row[];
    },
  });

  const rows = preview.data ?? [];
  const totals = useMemo(
    () =>
      rows.reduce(
        (a, r) => ({
          net: a.net + Number(r.net_pay),
          hours: a.hours + Number(r.worked_hours),
          pen: a.pen + Number(r.penalties),
          bon: a.bon + Number(r.bonuses),
        }),
        { net: 0, hours: 0, pen: 0, bon: 0 },
      ),
    [rows],
  );

  const [selected, setSelected] = useState<Row | null>(null);
  const superAdmin = useQuery({ queryKey: ["is-super-admin"], queryFn: async () => Boolean((await supabase.rpc("is_super_admin")).data) });
  const [q, setQ] = useState("");
  const shownRows = rows.filter((r) => matches(q, r.employee_name, r.job_title));

  const pendingPenalties = useQuery({
    queryKey: ["hr-pending-penalties", start, end],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.from("staff_penalties").select("amount, staff_id, created_at, user_profiles!staff_penalties_staff_id_fkey(display_name, first_name)")
        .eq("is_settled", false)
        .gte("created_at", `${start}T00:00:00`)
        .lte("created_at", `${end}T23:59:59.999`);
      if (error) throw error;
      return data ?? [];
    },
  });

  const refresh = () => qc.invalidateQueries({ queryKey: ["hr-preview"] });

  const runPayroll = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("run_payroll", { _period_start: start, _period_end: end });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "تم إصدار رواتب الشهر" : "Payroll generated");
      refresh();
      qc.invalidateQueries({ queryKey: ["salary-payments"] });
    },
    onError: (e) =>
      toast.error(
        (e as Error).message?.includes("already generated")
          ? ar ? "رواتب هذا الشهر صدرت بالفعل" : "Payroll already generated for this month"
          : friendlyError(e, lang),
      ),
  });

  if (!canView) {
    return <NoPermission message={ar ? "هذه الصفحة للسوبر أدمن والشركاء فقط" : "Super Admin and partners only"} />;
  }

  return (
    <div className="animate-fade-in space-y-4">
      <PageHeader
        title={ar ? "الرواتب والمستحقات" : "Payroll & salaries"}
        description={
          ar
            ? "الراتب النسبي حسب تاريخ التعيين، ساعات العمل، الجزاءات والمكافآت، وصافي الدفع"
            : "Prorated salary by hire date, worked hours, penalties, bonuses and net pay"
        }
        action={
          <div className="flex flex-wrap items-end gap-2">
            <div>
              <Label className="text-xs">{ar ? "الشهر" : "Month"}</Label>
              <Input type="month" value={month} onChange={(e) => e.target.value && setMonth(e.target.value)} />
            </div>
            {manage && (
              <Button onClick={() => runPayroll.mutate()} disabled={runPayroll.isPending || rows.length === 0}>
                {ar ? "إصدار رواتب الشهر" : "Generate payroll"}
              </Button>
            )}
          </div>
        }
      />

      <ManagerPercentPayLines start={start} end={end} />
      <KpiGrid cols={3}>
        <KpiCard label={ar ? "إجمالي الموظفين النشطين" : "Active staff"} value={shownRows.length} tone="brand" formula={ar ? "عدد الموظفين النشطين المطابقين للبحث." : "Active employees matching the search."} details={<div className="space-y-2">{shownRows.map((row) => <div key={row.user_id} className="flex justify-between gap-3 rounded-lg border border-border p-3 text-sm"><span>{row.employee_name}</span><span className="text-muted-foreground">{row.job_title}</span></div>)}</div>} />
        <KpiCard label={ar ? "الجزاءات المعلقة (الشهر)" : "Pending penalties (month)"} value={money((pendingPenalties.data ?? []).reduce((sum, row) => sum + Number(row.amount), 0))} tone={(pendingPenalties.data ?? []).length > 0 ? "bad" : undefined} formula={ar ? "مجموع الجزاءات غير المسوّاة المسجلة داخل الشهر المختار." : "Unsettled penalties recorded in the selected month."} details={<div className="space-y-2">{(pendingPenalties.data ?? []).map((row, index) => { const profile = row.user_profiles as unknown as { display_name: string | null; first_name: string } | null; return <div key={`${row.staff_id}-${index}`} className="flex justify-between gap-3 rounded-lg border border-border p-3 text-sm"><span>{profile?.display_name || profile?.first_name || "—"}</span><span className="font-semibold tabular-nums text-destructive">{money(Number(row.amount))}</span></div>; })}</div>} />
        <KpiCard label={ar ? "إجمالي الرواتب" : "Total payroll"} value={money(shownRows.reduce((s, r) => s + Number(r.net_pay), 0))} hint={`${ar ? "ساعات" : "Hours"}: ${totals.hours.toFixed(1)}`} formula={ar ? "مجموع صافي رواتب الموظفين الظاهرين بعد الجزاءات والمكافآت." : "Sum of displayed employees' net pay after penalties and bonuses."} details={<div className="space-y-2">{shownRows.map((row) => <div key={row.user_id} className="flex justify-between gap-3 rounded-lg border border-border p-3 text-sm"><span>{row.employee_name}</span><span className="font-semibold tabular-nums">{money(Number(row.net_pay))}</span></div>)}</div>} />
      </KpiGrid>
      <div className="hidden">
        {[
          { l: ar ? "صافي الرواتب" : "Net payroll", v: money(totals.net) },
          { l: ar ? "ساعات العمل" : "Worked hours", v: totals.hours.toFixed(1) },
          { l: ar ? "الجزاءات" : "Penalties", v: money(totals.pen) },
          { l: ar ? "المكافآت" : "Bonuses", v: money(totals.bon) },
        ].map((c) => (
          <Card key={c.l}>
            <CardHeader className="pb-1">
              <CardTitle className="text-sm font-medium text-muted-foreground">{c.l}</CardTitle>
            </CardHeader>
            <CardContent className="pt-0 text-2xl font-bold">{c.v}</CardContent>
          </Card>
        ))}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <div className="flex-1">
          <SmartFilterBar search={q} onSearch={setQ} placeholder={ar ? "ابحث باسم الموظف أو الوظيفة…" : "Search staff or job…"} />
        </div>
      </div>
      <Card>
        <CardContent className="overflow-x-auto p-0">
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-muted-foreground">
              <tr className="[&>th]:px-3 [&>th]:py-2 [&>th]:text-start">
                <th>{ar ? "الموظف" : "Employee"}</th>
                <th>{ar ? "تاريخ التعيين" : "Hire date"}</th>
                <th>{ar ? "الأساسي" : "Base"}</th>
                <th>{ar ? "النسبي" : "Prorated"}</th>
                <th>{ar ? "أيام / ساعات" : "Days / hours"}</th>
                <th>{ar ? "غياب" : "Absence"}</th>
                <th>{ar ? "جزاءات" : "Penalties"}</th>
                <th>{ar ? "سلف" : "Advances"}</th>
                <th>{ar ? "مُرحّل للشهر الجاي" : "Carried"}</th>
                <th>{ar ? "مكافآت" : "Bonuses"}</th>
                <th>{ar ? "صافي الدفع" : "Net pay"}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {preview.isLoading && (
                <tr>
                  <td colSpan={12} className="p-6 text-center text-muted-foreground">
                    {ar ? "جاري التحميل..." : "Loading..."}
                  </td>
                </tr>
              )}
              {!preview.isLoading && rows.length === 0 && (
                <tr>
                  <td colSpan={12} className="p-6 text-center text-muted-foreground">
                    {ar ? "لا يوجد موظفون." : "No employees yet."}
                  </td>
                </tr>
              )}
              {shownRows.map((r) => (
                <tr key={r.user_id} onClick={() => setSelected(r)} className="cursor-pointer border-t hover:bg-muted/40 [&>td]:px-3 [&>td]:py-2">
                  <td className="font-medium">{r.employee_name}{r.job_title && <span className="block text-xs text-muted-foreground">{ar ? JOB_TITLES[r.job_title]?.ar : JOB_TITLES[r.job_title]?.en}</span>}</td>
                  <td>{r.hire_date ?? "—"}</td>
                  <td>{money(r.base_salary)}</td>
                  <td>{money(r.prorated_salary)}</td>
                  <td>
                    {r.worked_days} / {Number(r.worked_hours).toFixed(1)}
                  </td>
                  <td className="text-destructive">
                    {r.absent_days > 0 ? `${r.absent_days} · ${money(r.absence_deduction)}` : "—"}
                  </td>
                  <td className="text-destructive">{money(r.penalties)}</td>
                  <td className="text-destructive">{money(r.advances)}</td>
                  <td className={Number(r.carried_forward) > 0 ? "text-amber-600" : "text-muted-foreground"}>{Number(r.carried_forward) > 0 ? money(r.carried_forward) : "—"}</td>
                  <td className="text-primary">{money(r.bonuses)}</td>
                  <td className="font-bold">{money(r.net_pay)}</td>
                  <td>
                    <div className="flex items-center gap-1">
                      {r.already_generated && <Badge variant="secondary">{ar ? "صدر" : "Issued"}</Badge>}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
      <p className="text-xs text-muted-foreground">
        {ar
          ? "اضغط على أي موظف لتعديل بياناته وإضافة مكافأة أو خصم. الخصم بيمشي بالترتيب: الغياب، بعدين الجزاءات، بعدين السلف — ومش بيعدّي المرتب أبداً. أي باقي بيتنقل للشهر الجاي في عمود «مُرحّل» ومش بيتمسح."
          : "Click any employee to edit, add bonuses or penalties. Deductions go absence → penalties → advances and never exceed pay. Anything left rolls to next month (Carried) — it is never wiped."}
      </p>

      <EmployeeDrawer row={selected ? rows.find((x) => x.user_id === selected.user_id) ?? selected : null} onClose={() => setSelected(null)} editable={superAdmin.data === true} canBonus={manage} currency={currency} periodEnd={end} />
    </div>
  );
}
