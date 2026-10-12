import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { ProfitCenter } from "@/modules/finance/ProfitCenter";
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
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { businessToday, monthToDate } from "@/core/finance/business-dates";


export type FinanceSection = "expenses" | "profit";

export function FinancePage({
  sections = ["expenses", "profit"],
  bare = false,
}: {
  sections?: FinanceSection[];
  bare?: boolean;
}) {
  const { t, lang } = useI18n();
  const { can } = useAuth();

  const canExpenses = sections.includes("expenses") && can("expenses.view");
  const canProfit =
    sections.includes("profit") && (can("partners.view_profit") || can("reports.profit"));

  if (!canExpenses && !canProfit) {
    return <NoPermission message={t("common.noAccess")} />;
  }

  const first = canExpenses ? "expenses" : "profit";
  const single = !(canExpenses && canProfit);

  return (
    <div>
      {!bare && <PageHeader title={t("fin.title")} description={t("fin.subtitle")} />}
      <Tabs defaultValue={first}>
        {!single && (
          <TabsList>
            {canExpenses && <TabsTrigger value="expenses">{t("fin.expenses")}</TabsTrigger>}
            {canProfit && <TabsTrigger value="profit">{t("fin.profit")}</TabsTrigger>}
          </TabsList>
        )}
        {canExpenses && (
          <TabsContent value="expenses" className="mt-4">
            <ExpensesTab />
          </TabsContent>
        )}
        {canProfit && (
          <TabsContent value="profit" className="mt-4">
            <ProfitTab />
          </TabsContent>
        )}
      </Tabs>
      <p className="mt-4 text-xs text-muted-foreground">{t("fin.appendOnly")}</p>
    </div>
  );
}


/* ------------------------------- EXPENSES ------------------------------- */

function ExpensesTab() {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";

  const [open, setOpen] = useState(false);
  const [categoryId, setCategoryId] = useState("");
  const [amount, setAmount] = useState("");
  const [date, setDate] = useState(businessToday());
  const [method, setMethod] = useState("cash");
  const [vendor, setVendor] = useState("");
  const [description, setDescription] = useState("");
  const [correctTarget, setCorrectTarget] = useState<{ id: string; amount: number } | null>(null);
  const [correctAmount, setCorrectAmount] = useState("");
  const [correctReason, setCorrectReason] = useState("");
  const isSuperAdmin = Boolean(me?.roleNames.includes("Super Admin"));


  const { data: categories } = useQuery({
    queryKey: ["expense-categories"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("expense_categories")
        .select("id, name, name_ar, is_active")
        .eq("is_active", true)
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: expenses } = useQuery({
    queryKey: ["expenses"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("expenses")
        .select(
          "id, amount, expense_date, payment_method, vendor, description, status, approved_at, branch_id, expense_categories(name, name_ar), branches(name)",
        )
        .order("expense_date", { ascending: false })
        .limit(200);
      if (error) throw error;
      return data ?? [];
    },
  });

  // This month's active expenses, queried on their own so the card never depends on the list limit.
  const month = monthToDate();
  const { data: totals = 0 } = useQuery({
    queryKey: ["expenses", "month-total", month.start],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("expenses")
        .select("amount")
        .eq("status", "active")
        .gte("expense_date", month.start)
        .lte("expense_date", month.end);
      if (error) throw error;
      return (data ?? []).reduce((sum, row) => sum + Number(row.amount), 0);
    },
  });

  const createExpense = useMutation({
    mutationFn: async () => {
      const value = Number(amount);
      if (!Number.isFinite(value) || value <= 0) throw new Error("amount");
      const { error } = await supabase.rpc("create_expense_entry", {
        _amount: value,
        _expense_date: date,
        _payment_method: method,
        ...(categoryId ? { _category_id: categoryId } : {}),
        ...(currentBranchId ? { _branch_id: currentBranchId } : {}),
        ...(vendor ? { _vendor: vendor } : {}),
        ...(description ? { _description: description } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(t("common.saved"));
      setOpen(false);
      setAmount("");
      setVendor("");
      setDescription("");
      queryClient.invalidateQueries({ queryKey: ["expenses"] });
    },
    onError: (error) =>
      toast.error(
        (error as Error).message === "amount" ? t("fin.invalidAmount") : friendlyError(error, lang),
      ),
  });

  const setStatus = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: "active" | "cancelled" }) => {
      const { error } = await supabase.rpc("review_expense", {
        _expense_id: id,
        _decision: status === "cancelled" ? "cancel" : "restore",
      });
      if (error) throw error;
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["expenses"] }),
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const approve = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc("review_expense", {
        _expense_id: id,
        _decision: "approve",
      });
      if (error) throw error;
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["expenses"] }),
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Super-admin-only amount correction: keeps the original entry, logs the old
  // and new value plus a mandatory reason, and posts the cash difference.
  const correctAmountMutation = useMutation({
    mutationFn: async () => {
      const value = Number(correctAmount);
      if (!Number.isFinite(value) || value <= 0) throw new Error("amount");
      const { error } = await supabase.rpc("correct_expense_amount", {
        _expense_id: correctTarget!.id,
        _new_amount: value,
        _reason: correctReason.trim(),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(t("common.saved"));
      setCorrectTarget(null);
      setCorrectAmount("");
      setCorrectReason("");
      queryClient.invalidateQueries({ queryKey: ["expenses"] });
    },
    onError: (error) =>
      toast.error(
        (error as Error).message === "amount" ? t("fin.invalidAmount") : friendlyError(error, lang),
      ),
  });


  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <Card className="min-w-[220px]">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              {t("fin.totalExpenses")}
            </CardTitle>
          </CardHeader>
          <CardContent className="pt-0 text-2xl font-bold">
            {formatMoney(totals, currency, lang)}
          </CardContent>
        </Card>

        {can("expenses.create") && (
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button>{t("fin.newExpense")}</Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>{t("fin.newExpense")}</DialogTitle>
              </DialogHeader>
              <div className="space-y-3">
                <div>
                  <Label>{t("fin.category")}</Label>
                  <Select value={categoryId} onValueChange={setCategoryId}>
                    <SelectTrigger>
                      <SelectValue placeholder={t("fin.category")} />
                    </SelectTrigger>
                    <SelectContent>
                      {(categories ?? []).map((category) => (
                        <SelectItem key={category.id} value={category.id}>
                          {lang === "ar" ? (category.name_ar ?? category.name) : category.name}
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
                      min="0"
                      step="0.01"
                      value={amount}
                      onChange={(event) => setAmount(event.target.value)}
                    />
                  </div>
                  <div>
                    <Label>{t("common.date")}</Label>
                    <Input
                      type="date"
                      value={date}
                      onChange={(event) => setDate(event.target.value)}
                    />
                  </div>
                </div>
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <Label>{t("fin.method")}</Label>
                    <Select value={method} onValueChange={setMethod}>
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="cash">{t("fin.method.cash")}</SelectItem>
                        <SelectItem value="bank">{t("fin.method.bank")}</SelectItem>
                        <SelectItem value="wallet">{t("fin.method.wallet")}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div>
                    <Label>{t("fin.vendor")}</Label>
                    <Input value={vendor} onChange={(event) => setVendor(event.target.value)} />
                  </div>
                </div>
                <div>
                  <Label>{t("common.notes")}</Label>
                  <Textarea
                    value={description}
                    onChange={(event) => setDescription(event.target.value)}
                  />
                </div>
              </div>
              <DialogFooter>
                <Button variant="outline" onClick={() => setOpen(false)}>
                  {t("common.cancel")}
                </Button>
                <Button onClick={() => createExpense.mutate()} disabled={createExpense.isPending}>
                  {t("common.save")}
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        )}
      </div>

      {!expenses || expenses.length === 0 ? (
        <EmptyState message={t("fin.noExpenses")} />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("common.date")}</TableHead>
                <TableHead>{t("fin.category")}</TableHead>
                <TableHead>{t("fin.vendor")}</TableHead>
                <TableHead>{t("common.amount")}</TableHead>
                <TableHead>{t("common.status")}</TableHead>
                <TableHead>{t("common.actions")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {expenses.map((row) => {
                const category = row.expense_categories as {
                  name: string;
                  name_ar: string | null;
                } | null;
                return (
                  <TableRow key={row.id}>
                    <TableCell>{formatDate(row.expense_date, lang)}</TableCell>
                    <TableCell>
                      {category
                        ? lang === "ar"
                          ? (category.name_ar ?? category.name)
                          : category.name
                        : "—"}
                    </TableCell>
                    <TableCell className="max-w-[180px] truncate">
                      {row.vendor || row.description || "—"}
                    </TableCell>
                    <TableCell className="font-medium">
                      {formatMoney(row.amount, currency, lang)}
                    </TableCell>
                    <TableCell>
                      <Badge variant={row.status === "active" ? "secondary" : "outline"}>
                        {row.status === "active"
                          ? row.approved_at
                            ? t("fin.approved")
                            : t("fin.pending")
                          : t("fin.cancelled")}
                      </Badge>
                    </TableCell>
                    <TableCell className="space-x-2 whitespace-nowrap">
                      {can("expenses.approve") && row.status === "active" && !row.approved_at && (
                        <Button size="sm" variant="outline" onClick={() => approve.mutate(row.id)}>
                          {t("fin.approve")}
                        </Button>
                      )}
                      {isSuperAdmin && row.status === "active" && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => {
                            setCorrectTarget({ id: row.id, amount: Number(row.amount) });
                            setCorrectAmount(String(row.amount));
                            setCorrectReason("");
                          }}
                        >
                          {t("fin.correctAmount")}
                        </Button>
                      )}
                      {can("expenses.edit") && row.status === "active" && (
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => setStatus.mutate({ id: row.id, status: "cancelled" })}
                        >
                          {t("fin.cancel")}
                        </Button>
                      )}

                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      <Dialog open={Boolean(correctTarget)} onOpenChange={(v) => !v && setCorrectTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("fin.correctAmount")}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="text-xs text-muted-foreground">{t("fin.correctAmountHint")}</p>
            <div className="space-y-1">
              <Label>{t("common.amount")}</Label>
              <Input
                type="number"
                min="0"
                step="0.01"
                value={correctAmount}
                onChange={(e) => setCorrectAmount(e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <Label>{t("fin.correctReason")}</Label>
              <Input
                value={correctReason}
                onChange={(e) => setCorrectReason(e.target.value)}
                placeholder={t("fin.correctReason")}
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              disabled={correctReason.trim().length < 5 || correctAmountMutation.isPending}
              onClick={() => correctAmountMutation.mutate()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );

}

/* -------------------------------- PROFIT -------------------------------- */

function ProfitTab() {
  return <ProfitCenter />;
}
