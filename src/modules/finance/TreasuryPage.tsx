import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useMemo, useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Pagination } from "@/components/shared";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { ExportCsvButton } from "@/components/ui/export-button";
import type { CsvColumn } from "@/lib/csv";
import { businessMonth, businessToday, monthBounds } from "@/core/finance/business-dates";

type MovementExportRow = {
  txn_date: string;
  account: string;
  direction: string;
  amount: number;
  method: string;
  category: string;
  description: string;
  status: string;
};

const MOVEMENT_COLUMNS: Array<CsvColumn<MovementExportRow>> = [
  { header: "Date", value: (r) => r.txn_date },
  { header: "Account", value: (r) => r.account },
  { header: "Direction", value: (r) => r.direction },
  { header: "Amount", value: (r) => r.amount },
  { header: "Method", value: (r) => r.method },
  { header: "Category", value: (r) => r.category },
  { header: "Description", value: (r) => r.description },
  { header: "Status", value: (r) => r.status },
];

const PAGE_SIZE = 25;

type Overview = {
  accounts: Array<{
    id: string;
    key: string;
    name: string;
    name_ar: string | null;
    type: string;
    is_active: boolean;
    balance: number;
  }>;
  open_drawers: number;
  total: number;
};

type Costs = {
  from: string;
  to: string;
  sales: number;
  cogs: number;
  waste: number;
  purchases_total: number;
  purchases_paid: number;
  purchases_due: number;
  payroll: number;
  advances: number;
  expenses: number;
  operating_total: number;
  consumption: Array<{
    item: string;
    item_ar: string | null;
    unit: string;
    qty: number;
    cost: number;
  }>;
  expense_breakdown: Array<{ category: string; category_ar: string | null; amount: number }>;
};

const CATEGORY_LABELS: Record<string, { en: string; ar: string }> = {
  shift_deposit: { en: "Shift deposit", ar: "توريد وردية" },
  electronic_settlement: { en: "Card & wallet takings", ar: "تحصيل فيزا ومحافظ" },
  drawer_float: { en: "Drawer float", ar: "عهدة الدرج" },
  development_fund: { en: "Development fund", ar: "صندوق التطوير" },
  purchase_payment: { en: "Supplier payment", ar: "دفع لمورد" },
  expense: { en: "Expense", ar: "مصروف" },
  salary: { en: "Salary", ar: "راتب" },
  partner_withdrawal: { en: "Partner withdrawal", ar: "سحب شريك" },
  partner_tab_settlement: { en: "Partner tab payment", ar: "سداد حساب شريك" },
  capital_contribution: { en: "Capital", ar: "رأس مال" },
  transfer_in: { en: "Transfer in", ar: "تحويل داخل" },
  transfer_out: { en: "Transfer out", ar: "تحويل خارج" },
  manual: { en: "Manual", ar: "يدوي" },
};

function monthRange() {
  const { start, end } = monthBounds(businessMonth());
  return { from: start, to: end };
}

export function TreasuryPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  const ar = lang === "ar";
  const canView = can("treasury.view");
  const canManage = can("treasury.manage");
  const range = useMemo(monthRange, []);
  const [from, setFrom] = useState(range.from);
  const [to, setTo] = useState(range.to);
  const [page, setPage] = useState(0);

  const [entryOpen, setEntryOpen] = useState(false);
  const [entry, setEntry] = useState({
    account_id: "",
    direction: "out",
    amount: "",
    method: "cash",
    date: businessToday(),
    description: "",
  });
  const [transferOpen, setTransferOpen] = useState(false);
  const [transfer, setTransfer] = useState({
    from: "",
    to: "",
    amount: "",
    date: businessToday(),
  });

  const overview = useQuery({
    queryKey: ["treasury-overview"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("treasury_overview");
      if (error) throw error;
      return data as unknown as Overview;
    },
  });

  // One page of rows only; the range totals below come from a dedicated server aggregate.
  const movements = useQuery({
    queryKey: ["treasury-movements", from, to, page],
    enabled: canView,
    queryFn: async () => {
      const { data, error, count } = await supabase
        .from("cash_transactions")
        .select(
          "id, txn_date, direction, amount, method, category, description, account_id, status",
          { count: "exact" },
        )
        .gte("txn_date", from)
        .lte("txn_date", to)
        .order("txn_date", { ascending: false })
        .order("created_at", { ascending: false })
        .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);
      if (error) throw error;
      return { rows: data ?? [], total: count ?? 0 };
    },
  });

  const flow = useQuery({
    queryKey: ["treasury-flow", from, to],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("cash_movements_summary", {
        _from: from,
        _to: to,
      });
      if (error) throw error;
      return data as unknown as { count: number; total_in: number; total_out: number; net: number };
    },
  });

  const costs = useQuery({
    queryKey: ["operating-costs", from, to],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("monthly_operating_costs", {
        _from: from,
        _to: to,
      });
      if (error) throw error;
      return data as unknown as Costs;
    },
  });

  const saveEntry = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("treasury_entry", {
        _account_id: entry.account_id,
        _direction: entry.direction,
        _amount: Number(entry.amount),
        _method: entry.method,
        _txn_date: entry.date,
        _description: entry.description,
        _category: "manual",
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setEntryOpen(false);
      setEntry({ ...entry, amount: "", description: "" });
      queryClient.invalidateQueries({ queryKey: ["treasury-overview"] });
      queryClient.invalidateQueries({ queryKey: ["treasury-movements"] });
      queryClient.invalidateQueries({ queryKey: ["treasury-flow"] });

      toast.success(ar ? "تم تسجيل الحركة." : "Movement recorded.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const saveTransfer = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("transfer_cash", {
        _from_account: transfer.from,
        _to_account: transfer.to,
        _amount: Number(transfer.amount),
        _txn_date: transfer.date,
        _description: "",
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setTransferOpen(false);
      setTransfer({ ...transfer, amount: "" });
      queryClient.invalidateQueries({ queryKey: ["treasury-overview"] });
      queryClient.invalidateQueries({ queryKey: ["treasury-movements"] });
      queryClient.invalidateQueries({ queryKey: ["treasury-flow"] });

      toast.success(ar ? "تم التحويل." : "Transfer done.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Export walks the whole filtered range on the server, page by page.
  const fetchAllMovements = useCallback(async (): Promise<MovementExportRow[]> => {
    const list = overview.data?.accounts ?? [];
    const nameOf = (id: string) => {
      const account = list.find((row) => row.id === id);
      if (!account) return "";
      return ar ? (account.name_ar ?? account.name) : account.name;
    };
    const out: MovementExportRow[] = [];
    const chunk = 1000;
    for (let offset = 0; ; offset += chunk) {
      const { data, error } = await supabase
        .from("cash_transactions")
        .select(
          "id, txn_date, direction, amount, method, category, description, account_id, status",
        )
        .gte("txn_date", from)
        .lte("txn_date", to)
        .order("txn_date", { ascending: false })
        .order("created_at", { ascending: false })
        .range(offset, offset + chunk - 1);
      if (error) throw error;
      for (const row of data ?? []) {
        out.push({
          txn_date: row.txn_date,
          account: nameOf(row.account_id),
          direction: row.direction,
          amount: Number(row.amount),
          method: row.method,
          category: row.category,
          description: row.description ?? "",
          status: row.status,
        });
      }
      if ((data ?? []).length < chunk) break;
    }
    return out;
  }, [overview.data, ar, from, to]);

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const accounts = overview.data?.accounts ?? [];
  const accountName = (id: string) => {
    const account = accounts.find((row) => row.id === id);
    if (!account) return "—";
    return ar ? (account.name_ar ?? account.name) : account.name;
  };
  const cost = costs.data;

  return (
    <div>
      <PageHeader
        title={ar ? "الخزنة المركزية" : "Central treasury"}
        description={
          ar
            ? "كل فلوس الكافيه في مكان واحد: الداخل والخارج والتحويلات والتكاليف التشغيلية."
            : "All cash in one place: inflows, outflows, transfers and operating costs."
        }
        action={
          <div className="flex flex-wrap gap-2">
            <ExportCsvButton
              fetchRows={fetchAllMovements}
              columns={MOVEMENT_COLUMNS}
              filePrefix="treasury-movements"
              size="default"
            />

            {canManage && (
              <>
                <Button variant="outline" onClick={() => setTransferOpen(true)}>
                  {ar ? "تحويل بين الحسابات" : "Transfer"}
                </Button>
                <Button onClick={() => setEntryOpen(true)}>
                  {ar ? "حركة جديدة" : "New movement"}
                </Button>
              </>
            )}
          </div>
        }
      />

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {accounts.map((account) => (
          <Card key={account.id}>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium text-muted-foreground">
                {ar ? (account.name_ar ?? account.name) : account.name}
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-semibold tabular-nums">
                {formatMoney(account.balance, currency, lang)}
              </p>
            </CardContent>
          </Card>
        ))}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              {ar ? "أدراج الورديات المفتوحة" : "Open drawers"}
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-semibold tabular-nums">
              {formatMoney(overview.data?.open_drawers ?? 0, currency, lang)}
            </p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              {ar ? "إجمالي السيولة" : "Total cash"}
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-semibold tabular-nums">
              {formatMoney(overview.data?.total ?? 0, currency, lang)}
            </p>
          </CardContent>
        </Card>
      </div>

      <div className="mt-6 flex flex-wrap items-end gap-3">
        <div>
          <Label>{ar ? "من" : "From"}</Label>
          <Input
            type="date"
            value={from}
            onChange={(event) => {
              setFrom(event.target.value);
              setPage(0);
            }}
          />
        </div>
        <div>
          <Label>{ar ? "إلى" : "To"}</Label>
          <Input
            type="date"
            value={to}
            onChange={(event) => {
              setTo(event.target.value);
              setPage(0);
            }}
          />
        </div>
      </div>

      {/* Range totals are computed on the server, so paging never changes them. */}
      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        <div className="rounded-lg border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">{ar ? "داخل الفترة" : "Cash in"}</p>
          <p className="mt-1 text-xl font-bold tabular-nums text-emerald-600">
            {formatMoney(flow.data?.total_in ?? 0, currency, lang)}
          </p>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">{ar ? "خارج الفترة" : "Cash out"}</p>
          <p className="mt-1 text-xl font-bold tabular-nums text-destructive">
            {formatMoney(flow.data?.total_out ?? 0, currency, lang)}
          </p>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">{ar ? "الصافي" : "Net"}</p>
          <p className="mt-1 text-xl font-bold tabular-nums">
            {formatMoney(flow.data?.net ?? 0, currency, lang)}
          </p>
        </div>
      </div>

      <Tabs defaultValue="movements" className="mt-4">
        <div className="overflow-x-auto">
          <TabsList>
            <TabsTrigger value="movements">{ar ? "حركات الخزنة" : "Cash movements"}</TabsTrigger>
            <TabsTrigger value="costs">{ar ? "التكاليف التشغيلية" : "Operating costs"}</TabsTrigger>
            <TabsTrigger value="consumption">{ar ? "استهلاك البضاعة" : "Consumption"}</TabsTrigger>
          </TabsList>
        </div>

        <TabsContent value="movements">
          {(movements.data?.rows ?? []).length === 0 ? (
            <EmptyState message={ar ? "لا توجد حركات في الفترة." : "No movements in this range."} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t("common.date")}</TableHead>
                    <TableHead>{ar ? "الحساب" : "Account"}</TableHead>
                    <TableHead>{ar ? "البند" : "Category"}</TableHead>
                    <TableHead>{ar ? "طريقة الدفع" : "Method"}</TableHead>
                    <TableHead className="text-end">{ar ? "داخل" : "In"}</TableHead>
                    <TableHead className="text-end">{ar ? "خارج" : "Out"}</TableHead>
                    <TableHead>{ar ? "الوصف" : "Description"}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(movements.data?.rows ?? []).map((row) => (
                    <TableRow key={row.id}>
                      <TableCell className="whitespace-nowrap">
                        {formatDate(row.txn_date, lang)}
                      </TableCell>
                      <TableCell>{accountName(row.account_id)}</TableCell>
                      <TableCell>
                        <Badge variant={row.direction === "in" ? "secondary" : "outline"}>
                          {CATEGORY_LABELS[row.category]
                            ? CATEGORY_LABELS[row.category]![ar ? "ar" : "en"]
                            : row.category}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-muted-foreground">{row.method}</TableCell>
                      <TableCell className="text-end tabular-nums text-emerald-600">
                        {row.direction === "in" ? formatMoney(row.amount, currency, lang) : "—"}
                      </TableCell>
                      <TableCell className="text-end tabular-nums text-destructive">
                        {row.direction === "out" ? formatMoney(row.amount, currency, lang) : "—"}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {row.description ?? "—"}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
              <Pagination
                page={page}
                pageSize={PAGE_SIZE}
                total={movements.data?.total ?? 0}
                onPage={setPage}
                loading={movements.isFetching}
              />
            </div>
          )}
        </TabsContent>

        <TabsContent value="costs">
          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            {[
              {
                label: ar ? "إجمالي المبيعات" : "Total sales",
                value: cost?.sales ?? 0,
              },
              {
                label: ar ? "تكلفة البضاعة المستهلكة" : "Cost of goods sold",
                value: cost?.cogs ?? 0,
              },
              { label: ar ? "الهالك والجرد" : "Waste & stocktake", value: cost?.waste ?? 0 },
              { label: ar ? "الرواتب" : "Payroll", value: cost?.payroll ?? 0 },
              { label: ar ? "المصاريف" : "Expenses", value: cost?.expenses ?? 0 },
              {
                label: ar ? "إجمالي التشغيل" : "Total operating",
                value: cost?.operating_total ?? 0,
              },
              { label: ar ? "مشتريات الفترة" : "Purchases", value: cost?.purchases_total ?? 0 },
              {
                label: ar ? "مدفوع للموردين" : "Paid to suppliers",
                value: cost?.purchases_paid ?? 0,
              },
              { label: ar ? "باقي للموردين" : "Due to suppliers", value: cost?.purchases_due ?? 0 },
              { label: ar ? "سلف الموظفين" : "Employee advances", value: cost?.advances ?? 0 },
            ].map((row) => (
              <Card key={row.label}>
                <CardHeader className="pb-2">
                  <CardTitle className="text-sm font-medium text-muted-foreground">
                    {row.label}
                  </CardTitle>
                </CardHeader>
                <CardContent>
                  <p className="text-xl font-semibold tabular-nums">
                    {formatMoney(row.value, currency, lang)}
                  </p>
                </CardContent>
              </Card>
            ))}
          </div>

          {(cost?.expense_breakdown ?? []).length > 0 && (
            <div className="mt-6 overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{ar ? "بند المصروف" : "Expense category"}</TableHead>
                    <TableHead className="text-end">{t("common.amount")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(cost?.expense_breakdown ?? []).map((row) => (
                    <TableRow key={row.category}>
                      <TableCell>{ar ? (row.category_ar ?? row.category) : row.category}</TableCell>
                      <TableCell className="text-end tabular-nums">
                        {formatMoney(row.amount, currency, lang)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="consumption">
          {(cost?.consumption ?? []).length === 0 ? (
            <EmptyState
              message={ar ? "لا يوجد استهلاك في الفترة." : "No consumption in this range."}
            />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{ar ? "الصنف" : "Item"}</TableHead>
                    <TableHead className="text-end">{ar ? "الكمية" : "Qty"}</TableHead>
                    <TableHead className="text-end">{ar ? "التكلفة" : "Cost"}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(cost?.consumption ?? []).map((row) => (
                    <TableRow key={row.item}>
                      <TableCell>{ar ? (row.item_ar ?? row.item) : row.item}</TableCell>
                      <TableCell className="text-end tabular-nums">
                        {row.qty} {row.unit}
                      </TableCell>
                      <TableCell className="text-end tabular-nums">
                        {formatMoney(row.cost, currency, lang)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>
      </Tabs>

      <Dialog open={entryOpen} onOpenChange={setEntryOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{ar ? "حركة خزنة جديدة" : "New cash movement"}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <Label>{ar ? "الحساب" : "Account"}</Label>
              <Select
                value={entry.account_id}
                onValueChange={(value) => setEntry({ ...entry, account_id: value })}
              >
                <SelectTrigger>
                  <SelectValue placeholder={ar ? "اختر الحساب" : "Select account"} />
                </SelectTrigger>
                <SelectContent>
                  {accounts.map((account) => (
                    <SelectItem key={account.id} value={account.id}>
                      {ar ? (account.name_ar ?? account.name) : account.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <Label>{ar ? "النوع" : "Direction"}</Label>
                <Select
                  value={entry.direction}
                  onValueChange={(value) => setEntry({ ...entry, direction: value })}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="in">{ar ? "دخول فلوس" : "Cash in"}</SelectItem>
                    <SelectItem value="out">{ar ? "خروج فلوس" : "Cash out"}</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div>
                <Label>{t("common.amount")}</Label>
                <Input
                  type="number"
                  min="0.01"
                  step="0.01"
                  value={entry.amount}
                  onChange={(event) => setEntry({ ...entry, amount: event.target.value })}
                />
              </div>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <Label>{ar ? "طريقة الدفع" : "Method"}</Label>
                <Select
                  value={entry.method}
                  onValueChange={(value) => setEntry({ ...entry, method: value })}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="cash">{ar ? "كاش" : "Cash"}</SelectItem>
                    <SelectItem value="card">{ar ? "فيزا" : "Card"}</SelectItem>
                    <SelectItem value="transfer">{ar ? "تحويل بنكي" : "Bank transfer"}</SelectItem>
                    <SelectItem value="wallet">{ar ? "محفظة إلكترونية" : "E-wallet"}</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div>
                <Label>{t("common.date")}</Label>
                <Input
                  type="date"
                  value={entry.date}
                  onChange={(event) => setEntry({ ...entry, date: event.target.value })}
                />
              </div>
            </div>
            <div>
              <Label>{ar ? "الوصف" : "Description"}</Label>
              <Input
                value={entry.description}
                onChange={(event) => setEntry({ ...entry, description: event.target.value })}
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              disabled={!entry.account_id || Number(entry.amount) <= 0 || saveEntry.isPending}
              onClick={() => saveEntry.mutate()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={transferOpen} onOpenChange={setTransferOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{ar ? "تحويل بين الحسابات" : "Transfer between accounts"}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <Label>{ar ? "من حساب" : "From"}</Label>
              <Select
                value={transfer.from}
                onValueChange={(value) => setTransfer({ ...transfer, from: value })}
              >
                <SelectTrigger>
                  <SelectValue placeholder={ar ? "اختر الحساب" : "Select account"} />
                </SelectTrigger>
                <SelectContent>
                  {accounts.map((account) => (
                    <SelectItem key={account.id} value={account.id}>
                      {ar ? (account.name_ar ?? account.name) : account.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div>
              <Label>{ar ? "إلى حساب" : "To"}</Label>
              <Select
                value={transfer.to}
                onValueChange={(value) => setTransfer({ ...transfer, to: value })}
              >
                <SelectTrigger>
                  <SelectValue placeholder={ar ? "اختر الحساب" : "Select account"} />
                </SelectTrigger>
                <SelectContent>
                  {accounts.map((account) => (
                    <SelectItem key={account.id} value={account.id}>
                      {ar ? (account.name_ar ?? account.name) : account.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <Label>{t("common.amount")}</Label>
                <Input
                  type="number"
                  min="0.01"
                  step="0.01"
                  value={transfer.amount}
                  onChange={(event) => setTransfer({ ...transfer, amount: event.target.value })}
                />
              </div>
              <div>
                <Label>{t("common.date")}</Label>
                <Input
                  type="date"
                  value={transfer.date}
                  onChange={(event) => setTransfer({ ...transfer, date: event.target.value })}
                />
              </div>
            </div>
          </div>
          <DialogFooter>
            <Button
              disabled={
                !transfer.from ||
                !transfer.to ||
                transfer.from === transfer.to ||
                Number(transfer.amount) <= 0 ||
                saveTransfer.isPending
              }
              onClick={() => saveTransfer.mutate()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
