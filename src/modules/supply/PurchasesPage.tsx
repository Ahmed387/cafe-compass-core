import { addDays, businessToday } from "@/core/finance/business-dates";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useMemo, useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Pagination } from "@/components/shared";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
import { compatibleUnits, toStockUnit, unitLabel } from "@/modules/supply/units";
import { ExportCsvButton } from "@/components/ui/export-button";
import type { CsvColumn } from "@/lib/csv";
import {
  AttachmentLink,
  ChoiceRow,
  FilePicker,
  SOURCE_LABEL,
  SupplierPayablesPanel,
  TERMS_LABEL,
  TermsBadge,
  attachPurchaseFile,
  payPurchase,
  type PaySource,
  type PaymentTerms,
} from "./purchase-payments";

type PurchaseExportRow = {
  invoice_number: string;
  purchase_date: string;
  total: number;
  paid: number;
  returned: number;
  due: number;
  status: string;
};

const PURCHASE_COLUMNS: Array<CsvColumn<PurchaseExportRow>> = [
  { header: "Invoice", value: (r) => r.invoice_number },
  { header: "Date", value: (r) => r.purchase_date },
  { header: "Total", value: (r) => r.total },
  { header: "Paid", value: (r) => r.paid },
  { header: "Returned", value: (r) => r.returned },
  { header: "Due", value: (r) => r.due },
  { header: "Status", value: (r) => r.status },
];

/** One invoice line as written on the supplier's paper: quantity in any unit + what the line cost. */
type Line = { item_id: string; quantity: string; unit: string; line_total: string };
const EMPTY_LINE: Line = { item_id: "", quantity: "", unit: "", line_total: "" };

const PAGE_SIZE = 25;

function dayOffset(days: number) {
  return addDays(businessToday(), days);
}

type PurchaseRow = {
  id: string;
  invoice_number: string | null;
  purchase_date: string;
  total: number;
  paid_amount: number;
  returned_amount: number;
  status: string;
  purchase_items: {
    id: string;
    quantity: number;
    unit_cost: number;
    inventory_items: { name: string; name_ar: string | null; unit: string } | null;
    purchase_return_items: { quantity: number }[];
  }[];
};

export function PurchasesPage() {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";

  const canView = can("purchases.view") || can("inventory.view");
  const canCreate = can("purchases.create");
  const canCancel = can("purchases.cancel") || canCreate;
  const canManageSuppliers = can("suppliers.create") || can("suppliers.update") || canCreate;

  const [supplierDialog, setSupplierDialog] = useState(false);
  const [supplierForm, setSupplierForm] = useState({
    id: "",
    name: "",
    contact_person: "",
    phone: "",
    email: "",
    payment_terms: "",
  });

  const [purchaseDialog, setPurchaseDialog] = useState(false);
  const [supplierId, setSupplierId] = useState("");
  const [invoiceNumber, setInvoiceNumber] = useState("");
  const [purchaseDate, setPurchaseDate] = useState(() => businessToday());
  const [discountAmount, setDiscountAmount] = useState("");
  const [notes, setNotes] = useState("");
  const [paidNow, setPaidNow] = useState("");
  const [lines, setLines] = useState<Line[]>([EMPTY_LINE]);
  const [cancelTarget, setCancelTarget] = useState<{ id: string; label: string } | null>(null);
  const [cancelReason, setCancelReason] = useState("");
  const [payTarget, setPayTarget] = useState<{ id: string; label: string; due: number } | null>(
    null,
  );
  const [payAmount, setPayAmount] = useState("");
  const [paySource, setPaySource] = useState<PaySource>("treasury");
  const [terms, setTerms] = useState<PaymentTerms>("cash");
  const [cashSource, setCashSource] = useState<PaySource>("treasury");
  const [attachFile, setAttachFile] = useState<File | null>(null);
  const [payDate, setPayDate] = useState(() => businessToday());
  const [payNotes, setPayNotes] = useState("");
  const [pFrom, setPFrom] = useState(dayOffset(-89));
  const [pTo, setPTo] = useState(dayOffset(0));
  const [pStatus, setPStatus] = useState("all");
  const [page, setPage] = useState(0);

  const [returnTarget, setReturnTarget] = useState<PurchaseRow | null>(null);
  const [returnQty, setReturnQty] = useState<Record<string, string>>({});
  const [returnReason, setReturnReason] = useState("");
  const [refundMode, setRefundMode] = useState<"reduce_due" | "cash">("reduce_due");

  const suppliers = useQuery({
    queryKey: ["suppliers"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("suppliers")
        .select("id, name, contact_person, phone, email, payment_terms, is_active")
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const items = useQuery({
    queryKey: ["inventory-items-min"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("inventory_items")
        .select("id, name, name_ar, unit, cost_per_unit")
        .eq("is_active", true)
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  // One page of invoices; totals below come from a server aggregate over the whole range.
  const purchases = useQuery({
    queryKey: ["purchases", currentBranchId, pFrom, pTo, pStatus, page],
    enabled: canView && Boolean(currentBranchId),
    queryFn: async () => {
      let query = supabase
        .from("purchases")
        .select(
          "id, invoice_number, purchase_date, subtotal, tax_amount, discount_amount, total, paid_amount, returned_amount, status, payment_method, payment_terms, attachment_path, notes, cancel_reason, suppliers(name), purchase_items(id, quantity, unit_cost, line_total, inventory_items(name, name_ar, unit), purchase_return_items(quantity))",
          { count: "exact" },
        )
        .eq("branch_id", currentBranchId!)
        .gte("purchase_date", pFrom)
        .lte("purchase_date", pTo)
        .order("purchase_date", { ascending: false })
        .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);
      if (pStatus !== "all") query = query.eq("status", pStatus as "received");
      const { data, error, count } = await query;
      if (error) throw error;
      return { rows: data ?? [], total: count ?? 0 };
    },
  });

  const purchaseSummary = useQuery({
    queryKey: ["purchases-summary", currentBranchId, pFrom, pTo, pStatus],
    enabled: canView && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("purchases_period_summary", {
        _from: pFrom,
        _to: pTo,
        _branch_id: currentBranchId!,
        ...(pStatus === "all" ? {} : { _status: pStatus }),
      });
      if (error) throw error;
      return data as unknown as {
        count: number;
        total: number;
        paid: number;
        returned: number;
        due: number;
      };
    },
  });

  const saveSupplier = useMutation({
    mutationFn: async () => {
      // Empty strings clear the field; the RPC treats omitted (null) fields as unchanged.
      const payload = {
        name: supplierForm.name.trim(),
        contact_person: supplierForm.contact_person.trim(),
        phone: supplierForm.phone.trim(),
        email: supplierForm.email.trim(),
        payment_terms: supplierForm.payment_terms.trim(),
      };
      const { error } = await supabase.rpc("save_supplier", {
        ...Object.fromEntries(Object.entries(payload).map(([key, value]) => [`_${key}`, value])),
        ...(supplierForm.id ? { _id: supplierForm.id } : {}),
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setSupplierDialog(false);
      await queryClient.invalidateQueries({ queryKey: ["suppliers"] });
      toast.success(t("common.saved"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const toggleSupplier = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }) => {
      // Omitted fields are left untouched by the RPC.
      const { error } = await supabase.rpc("save_supplier", { _id: id, _is_active: active });
      if (error) throw error;
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["suppliers"] });
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Invoice line -> stock-unit quantity and cost per stock unit.
  const stockLine = (l: Line) => {
    const item = (items.data ?? []).find((i) => i.id === l.item_id);
    const qty = toStockUnit(Number(l.quantity || 0), l.unit || item?.unit || "", item?.unit ?? "");
    const total = Number(l.line_total || 0);
    return { item, qty, total, unitCost: qty > 0 ? total / qty : 0 };
  };

  const createPurchase = useMutation({
    mutationFn: async () => {
      const payloadItems = lines
        .filter((l) => l.item_id && Number(l.quantity) > 0)
        .map((l) => {
          const { qty, unitCost } = stockLine(l);
          return { item_id: l.item_id, quantity: Math.round(qty * 10000) / 10000, unit_cost: Math.round(unitCost * 1e6) / 1e6 };
        });
      if (payloadItems.length === 0) throw new Error("Purchase has no items");
      // Catch unit mix-ups (e.g. a 1 kg bag price typed as the price of 1 g) before they inflate recipe costs.
      const { data: warnings } = await supabase.rpc("purchase_cost_warnings", { _items: payloadItems });
      const flagged = (warnings ?? []) as Array<{ name: string; unit: string; current_cost: number; new_cost: number; ratio: number }>;
      if (flagged.length > 0) {
        const list = flagged.map((w) => `• ${w.name}: ${w.current_cost} → ${w.new_cost} / ${w.unit} (×${w.ratio})`).join("\n");
        const ok = window.confirm(
          lang === "ar"
            ? `السعر ده أعلى من المعتاد بأكتر من ١٠ مرات — غالباً الوحدة غلط (سعر الشيكارة اتكتب كسعر الجرام؟):\n${list}\n\nمتأكد إنه صح؟`
            : `These costs are over 10× the current cost — likely a unit mix-up:\n${list}\n\nSave anyway?`,
        );
        if (!ok) throw new Error(lang === "ar" ? "اتلغى الحفظ — راجع الكمية والوحدة" : "Cancelled — check quantity and unit");
      }
      const { data: purchaseId, error } = await supabase.rpc("create_purchase", {
        _branch_id: currentBranchId!,
        _supplier_id: supplierId,
        _items: payloadItems,
        _purchase_date: purchaseDate,
        _tax_amount: 0,
        _discount_amount: Number(discountAmount || 0),
        _receive: true,
        _payment_method: terms === "bank" ? "bank" : terms === "cash" ? "cash" : "credit",
        ...(invoiceNumber ? { _invoice_number: invoiceNumber } : {}),
        ...(notes ? { _notes: notes } : {}),
      });
      if (error) throw error;
      const id = purchaseId as string;
      const meta = await supabase.rpc("set_purchase_meta", { _purchase_id: id, _terms: terms });
      if (meta.error) throw meta.error;
      const { data: saved, error: readErr } = await supabase
        .from("purchases")
        .select("total")
        .eq("id", id)
        .single();
      if (readErr) throw readErr;
      const amount = terms === "credit" ? Number(paidNow || 0) : Number(saved.total);
      const source: PaySource = terms === "bank" ? "bank" : terms === "cash" ? cashSource : "treasury";
      // The purchase is saved and stocked first; a payment problem leaves it as an open debt.
      let payFailed: unknown = null;
      if (amount > 0) {
        try {
          await payPurchase(id, amount, source);
        } catch (e) {
          payFailed = e;
        }
      }
      if (attachFile) await attachPurchaseFile(me!.company!.id, id, attachFile);
      if (payFailed) throw payFailed;
    },
    onSettled: async () => {
      await queryClient.invalidateQueries({ queryKey: ["purchases"] });
      await queryClient.invalidateQueries({ queryKey: ["purchases-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["supplier-payables"] });
    },
    onSuccess: async () => {
      setPurchaseDialog(false);
      setLines([EMPTY_LINE]);
      setInvoiceNumber("");
      setDiscountAmount("");
      setNotes("");
      setPaidNow("");
      setAttachFile(null);
      await queryClient.invalidateQueries({ queryKey: ["stock"] });
      await queryClient.invalidateQueries({ queryKey: ["movements"] });
      await queryClient.invalidateQueries({ queryKey: ["financial-engine"] });
      toast.success(t("purch.received"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const cancelPurchase = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("cancel_purchase", {
        _purchase_id: cancelTarget!.id,
        _reason: cancelReason,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setCancelTarget(null);
      setCancelReason("");
      await queryClient.invalidateQueries({ queryKey: ["purchases"] });
      await queryClient.invalidateQueries({ queryKey: ["purchases-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["stock"] });
      toast.success(t("purch.cancelled"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const uploadFor = useMutation({
    mutationFn: async ({ id, file }: { id: string; file: File }) => {
      await attachPurchaseFile(me!.company!.id, id, file);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["purchases"] });
      toast.success("تم إرفاق الملف");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const recordPayment = useMutation({
    mutationFn: async () => {
      await payPurchase(payTarget!.id, Number(payAmount || 0), paySource, payNotes || undefined);
    },
    onSuccess: async () => {
      setPayTarget(null);
      setPayAmount("");
      setPayNotes("");
      await queryClient.invalidateQueries({ queryKey: ["purchases"] });
      await queryClient.invalidateQueries({ queryKey: ["purchases-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["supplier-payables"] });
      await queryClient.invalidateQueries({ queryKey: ["financial-engine"] });
      toast.success(t("purch.paymentSaved"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const returnItems = useMutation({
    mutationFn: async () => {
      const payload = Object.entries(returnQty)
        .filter(([, qty]) => Number(qty) > 0)
        .map(([purchase_item_id, qty]) => ({ purchase_item_id, quantity: Number(qty) }));
      if (payload.length === 0) throw new Error("No items to return");
      const { error } = await supabase.rpc("return_purchase_items", {
        _purchase_id: returnTarget!.id,
        _items: payload,
        _reason: returnReason,
        _refund_mode: refundMode,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setReturnTarget(null);
      setReturnQty({});
      setReturnReason("");
      await queryClient.invalidateQueries({ queryKey: ["purchases"] });
      await queryClient.invalidateQueries({ queryKey: ["purchases-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["stock"] });
      await queryClient.invalidateQueries({ queryKey: ["movements"] });
      toast.success(t("purch.returnSaved"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Export pulls the whole filtered range from the server, not just the visible page.
  const fetchAllPurchases = useCallback(async (): Promise<PurchaseExportRow[]> => {
    const out: PurchaseExportRow[] = [];
    const chunk = 1000;
    for (let offset = 0; ; offset += chunk) {
      let query = supabase
        .from("purchases")
        .select("invoice_number, purchase_date, total, paid_amount, returned_amount, status")
        .eq("branch_id", currentBranchId!)
        .gte("purchase_date", pFrom)
        .lte("purchase_date", pTo)
        .order("purchase_date", { ascending: false })
        .range(offset, offset + chunk - 1);
      if (pStatus !== "all") query = query.eq("status", pStatus as "received");
      const { data, error } = await query;
      if (error) throw error;
      for (const row of data ?? []) {
        out.push({
          invoice_number: row.invoice_number ?? "",
          purchase_date: row.purchase_date,
          total: Number(row.total),
          paid: Number(row.paid_amount),
          returned: Number(row.returned_amount ?? 0),
          due: Math.max(
            0,
            Number(row.total) - Number(row.paid_amount) - Number(row.returned_amount ?? 0),
          ),
          status: row.status,
        });
      }
      if ((data ?? []).length < chunk) break;
    }
    return out;
  }, [currentBranchId, pFrom, pTo, pStatus]);

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const itemName = (row: { name: string; name_ar?: string | null } | null | undefined) =>
    !row ? "—" : lang === "ar" ? row.name_ar || row.name : row.name;

  const linesTotal = lines.reduce((sum, l) => sum + Number(l.line_total || 0), 0);
  const grandTotal = linesTotal - Number(discountAmount || 0);

  const statusLabel = (status: string) =>
    status === "received"
      ? t("purch.statusReceived")
      : status === "cancelled"
        ? t("purch.statusCancelled")
        : t("purch.statusDraft");

  const dueOf = (row: { total: number; paid_amount: number; returned_amount: number }) =>
    Math.max(0, Number(row.total) - Number(row.returned_amount) - Number(row.paid_amount));

  const remainingQty = (line: PurchaseRow["purchase_items"][number]) =>
    Number(line.quantity) -
    (line.purchase_return_items ?? []).reduce((sum, r) => sum + Number(r.quantity), 0);

  return (
    <div>
      <PageHeader
        title={t("purch.title")}
        description={t("purch.subtitle")}
        action={
          <ExportCsvButton
            fetchRows={fetchAllPurchases}
            columns={PURCHASE_COLUMNS}
            filePrefix="purchases"
            size="default"
          />
        }
      />

      <Tabs defaultValue="purchases">
        <TabsList>
          <TabsTrigger value="purchases">{t("purch.invoices")}</TabsTrigger>
          <TabsTrigger value="suppliers">{t("purch.suppliers")}</TabsTrigger>
        </TabsList>

        <TabsContent value="purchases" className="mt-4 space-y-4">
          {canCreate && (
            <Button onClick={() => setPurchaseDialog(true)} disabled={!currentBranchId}>
              {t("purch.new")}
            </Button>
          )}

          <div className="flex flex-wrap items-end gap-3">
            <div className="grid gap-1">
              <Label htmlFor="purch-from">{t("range.from")}</Label>
              <Input
                id="purch-from"
                type="date"
                value={pFrom}
                onChange={(e) => {
                  setPFrom(e.target.value);
                  setPage(0);
                }}
              />
            </div>
            <div className="grid gap-1">
              <Label htmlFor="purch-to">{t("range.to")}</Label>
              <Input
                id="purch-to"
                type="date"
                value={pTo}
                onChange={(e) => {
                  setPTo(e.target.value);
                  setPage(0);
                }}
              />
            </div>
            <div className="grid gap-1">
              <Label htmlFor="purch-status">{t("common.status")}</Label>
              <select
                id="purch-status"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm"
                value={pStatus}
                onChange={(e) => {
                  setPStatus(e.target.value);
                  setPage(0);
                }}
              >
                <option value="all">{lang === "ar" ? "الكل" : "All"}</option>
                <option value="received">{t("purch.statusReceived")}</option>
                <option value="draft">{t("purch.statusDraft")}</option>
                <option value="cancelled">{t("purch.statusCancelled")}</option>
              </select>
            </div>
          </div>

          {/* Range totals from the server: paging cannot change them. */}
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-lg border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">{t("common.total")}</p>
              <p className="mt-1 text-xl font-bold tabular-nums">
                {formatMoney(purchaseSummary.data?.total ?? 0, currency, lang)}
              </p>
            </div>
            <div className="rounded-lg border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">{t("purch.paid")}</p>
              <p className="mt-1 text-xl font-bold tabular-nums">
                {formatMoney(purchaseSummary.data?.paid ?? 0, currency, lang)}
              </p>
            </div>
            <div className="rounded-lg border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">{t("purch.due")}</p>
              <p className="mt-1 text-xl font-bold tabular-nums text-destructive">
                {formatMoney(purchaseSummary.data?.due ?? 0, currency, lang)}
              </p>
            </div>
            <div className="rounded-lg border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">{t("purch.returned")}</p>
              <p className="mt-1 text-xl font-bold tabular-nums">
                {formatMoney(purchaseSummary.data?.returned ?? 0, currency, lang)}
              </p>
            </div>
          </div>

          <SupplierPayablesPanel currency={currency} lang={lang} />

          {(purchases.data?.rows ?? []).length === 0 ? (
            <EmptyState message={t("purch.empty")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t("purch.invoiceNumber")}</TableHead>
                    <TableHead>{t("common.date")}</TableHead>
                    <TableHead>{t("purch.supplier")}</TableHead>
                    <TableHead>{t("purch.itemsCol")}</TableHead>
                    <TableHead>{t("common.total")}</TableHead>
                    <TableHead>{t("purch.paid")}</TableHead>
                    <TableHead>{t("purch.due")}</TableHead>
                    <TableHead>شروط الدفع</TableHead>
                    <TableHead>المرفق</TableHead>
                    <TableHead>{t("common.status")}</TableHead>
                    <TableHead className="text-end">{t("common.actions")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(purchases.data?.rows ?? []).map((row) => (
                    <TableRow key={row.id}>
                      <TableCell className="font-medium">{row.invoice_number || "—"}</TableCell>
                      <TableCell>{formatDate(row.purchase_date, lang)}</TableCell>
                      <TableCell>{row.suppliers?.name ?? "—"}</TableCell>
                      <TableCell className="max-w-[260px] text-xs text-muted-foreground">
                        {row.purchase_items
                          .map(
                            (line) =>
                              `${Number(line.quantity)} ${line.inventory_items?.unit ?? ""} ${itemName(line.inventory_items)}`,
                          )
                          .join(", ")}
                      </TableCell>
                      <TableCell>{formatMoney(row.total, currency, lang)}</TableCell>
                      <TableCell className="tabular-nums">
                        {formatMoney(row.paid_amount, currency, lang)}
                      </TableCell>
                      <TableCell className="tabular-nums">
                        <span
                          className={
                            dueOf(row) > 0
                              ? "font-semibold text-destructive"
                              : "text-muted-foreground"
                          }
                        >
                          {formatMoney(dueOf(row), currency, lang)}
                        </span>
                        {Number(row.returned_amount) > 0 && (
                          <span className="ms-2 text-xs text-muted-foreground">
                            ({t("purch.returned")}{" "}
                            {formatMoney(row.returned_amount, currency, lang)})
                          </span>
                        )}
                      </TableCell>
                      <TableCell>
                        <TermsBadge terms={row.payment_terms} />
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center gap-1">
                          <AttachmentLink path={row.attachment_path} />
                          {canCreate && row.status !== "cancelled" && (
                            <label className="cursor-pointer text-xs text-primary underline">
                              {row.attachment_path ? "تغيير" : "إرفاق"}
                              <input
                                type="file"
                                accept="image/*,application/pdf"
                                className="hidden"
                                onChange={(e) => {
                                  const f = e.target.files?.[0];
                                  if (f) uploadFor.mutate({ id: row.id, file: f });
                                }}
                              />
                            </label>
                          )}
                        </div>
                      </TableCell>
                      <TableCell>
                        <Badge variant={row.status === "received" ? "secondary" : "outline"}>
                          {statusLabel(row.status)}
                        </Badge>
                      </TableCell>
                      <TableCell className="space-x-2 text-end">
                        {row.status === "received" && canCreate && dueOf(row) > 0 && (
                          <Button
                            size="sm"
                            variant="secondary"
                            onClick={() => {
                              setPayTarget({
                                id: row.id,
                                label: row.invoice_number || formatDate(row.purchase_date, lang),
                                due: dueOf(row),
                              });
                              setPayAmount(String(dueOf(row)));
                            }}
                          >
                            {t("purch.payment")}
                          </Button>
                        )}
                        {row.status === "received" && canCancel && (
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => {
                              setReturnTarget(row as unknown as PurchaseRow);
                              setReturnQty({});
                              setReturnReason("");
                              setRefundMode("reduce_due");
                            }}
                          >
                            {t("purch.return")}
                          </Button>
                        )}
                        {row.status !== "cancelled" && canCancel && (
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() =>
                              setCancelTarget({
                                id: row.id,
                                label: row.invoice_number || formatDate(row.purchase_date, lang),
                              })
                            }
                          >
                            {t("common.cancel")}
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
              <Pagination
                page={page}
                pageSize={PAGE_SIZE}
                total={purchases.data?.total ?? 0}
                onPage={setPage}
                loading={purchases.isFetching}
              />
            </div>
          )}
        </TabsContent>

        <TabsContent value="suppliers" className="mt-4 space-y-4">
          {canManageSuppliers && (
            <Button
              onClick={() => {
                setSupplierForm({
                  id: "",
                  name: "",
                  contact_person: "",
                  phone: "",
                  email: "",
                  payment_terms: "",
                });
                setSupplierDialog(true);
              }}
            >
              {t("purch.newSupplier")}
            </Button>
          )}
          {(suppliers.data ?? []).length === 0 ? (
            <EmptyState message={t("purch.noSuppliers")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t("common.name")}</TableHead>
                    <TableHead>{t("purch.contact")}</TableHead>
                    <TableHead>{t("common.phone")}</TableHead>
                    <TableHead>{t("purch.terms")}</TableHead>
                    <TableHead>{t("common.status")}</TableHead>
                    <TableHead className="text-end">{t("common.actions")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(suppliers.data ?? []).map((row) => (
                    <TableRow key={row.id}>
                      <TableCell className="font-medium">{row.name}</TableCell>
                      <TableCell>{row.contact_person || "—"}</TableCell>
                      <TableCell>{row.phone || "—"}</TableCell>
                      <TableCell>{row.payment_terms || "—"}</TableCell>
                      <TableCell>
                        <Badge variant={row.is_active ? "secondary" : "outline"}>
                          {row.is_active ? t("common.active") : t("common.inactive")}
                        </Badge>
                      </TableCell>
                      <TableCell className="space-x-2 text-end">
                        {canManageSuppliers && (
                          <>
                            <Button
                              size="sm"
                              variant="secondary"
                              onClick={() => {
                                setSupplierForm({
                                  id: row.id,
                                  name: row.name,
                                  contact_person: row.contact_person ?? "",
                                  phone: row.phone ?? "",
                                  email: row.email ?? "",
                                  payment_terms: row.payment_terms ?? "",
                                });
                                setSupplierDialog(true);
                              }}
                            >
                              {t("common.edit")}
                            </Button>
                            <Button
                              size="sm"
                              variant="outline"
                              onClick={() =>
                                toggleSupplier.mutate({ id: row.id, active: !row.is_active })
                              }
                            >
                              {row.is_active ? t("common.disable") : t("common.enable")}
                            </Button>
                          </>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>
      </Tabs>

      <Dialog open={supplierDialog} onOpenChange={setSupplierDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{supplierForm.id ? t("common.edit") : t("purch.newSupplier")}</DialogTitle>
          </DialogHeader>
          <div className="grid gap-3">
            <div>
              <Label>{t("common.name")}</Label>
              <Input
                className="mt-1"
                value={supplierForm.name}
                onChange={(e) => setSupplierForm({ ...supplierForm, name: e.target.value })}
              />
            </div>
            <div>
              <Label>{t("purch.contact")}</Label>
              <Input
                className="mt-1"
                value={supplierForm.contact_person}
                onChange={(e) =>
                  setSupplierForm({ ...supplierForm, contact_person: e.target.value })
                }
              />
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label>{t("common.phone")}</Label>
                <Input
                  className="mt-1"
                  value={supplierForm.phone}
                  onChange={(e) => setSupplierForm({ ...supplierForm, phone: e.target.value })}
                />
              </div>
              <div>
                <Label>{t("common.email")}</Label>
                <Input
                  className="mt-1"
                  value={supplierForm.email}
                  onChange={(e) => setSupplierForm({ ...supplierForm, email: e.target.value })}
                />
              </div>
            </div>
            <div>
              <Label>{t("purch.terms")}</Label>
              <Input
                className="mt-1"
                value={supplierForm.payment_terms}
                onChange={(e) =>
                  setSupplierForm({ ...supplierForm, payment_terms: e.target.value })
                }
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setSupplierDialog(false)}>
              {t("common.cancel")}
            </Button>
            <Button
              disabled={supplierForm.name.trim().length < 2 || saveSupplier.isPending}
              onClick={() => saveSupplier.mutate()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={purchaseDialog} onOpenChange={setPurchaseDialog}>
        <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle>{t("purch.new")}</DialogTitle>
          </DialogHeader>
          <div className="grid gap-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label>{t("purch.supplier")}</Label>
                <Select value={supplierId} onValueChange={setSupplierId}>
                  <SelectTrigger className="mt-1">
                    <SelectValue placeholder={t("purch.selectSupplier")} />
                  </SelectTrigger>
                  <SelectContent>
                    {(suppliers.data ?? [])
                      .filter((s) => s.is_active)
                      .map((s) => (
                        <SelectItem key={s.id} value={s.id}>
                          {s.name}
                        </SelectItem>
                      ))}
                  </SelectContent>
                </Select>
              </div>
              <div>
                <Label>{t("purch.invoiceNumber")}</Label>
                <Input
                  className="mt-1"
                  value={invoiceNumber}
                  onChange={(e) => setInvoiceNumber(e.target.value)}
                />
              </div>
              <div>
                <Label>{t("common.date")}</Label>
                <Input
                  type="date"
                  className="mt-1"
                  value={purchaseDate}
                  onChange={(e) => setPurchaseDate(e.target.value)}
                />
              </div>
            </div>

            <div className="space-y-2 rounded-lg border border-border p-3">
              <p className="text-sm font-semibold">{t("purch.itemsCol")}</p>
              {lines.map((line, index) => (
                <div key={index} className="space-y-1">
                <div className="grid gap-2 sm:grid-cols-[1fr_90px_90px_120px_auto]">
                  <Select
                    value={line.item_id}
                    onValueChange={(value) => {
                      const found = (items.data ?? []).find((i) => i.id === value);
                      setLines(lines.map((l, i) => (i === index ? { ...l, item_id: value, unit: found?.unit ?? "" } : l)));
                    }}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder={t("inv.selectItem")} />
                    </SelectTrigger>
                    <SelectContent>
                      {(items.data ?? []).map((i) => (
                        <SelectItem key={i.id} value={i.id}>
                          {itemName(i)} ({unitLabel(i.unit)})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Input
                    placeholder={t("common.quantity")}
                    inputMode="decimal"
                    value={line.quantity}
                    onChange={(e) => setLines(lines.map((l, i) => (i === index ? { ...l, quantity: e.target.value } : l)))}
                  />
                  <Select
                    value={line.unit}
                    disabled={!line.item_id}
                    onValueChange={(value) => setLines(lines.map((l, i) => (i === index ? { ...l, unit: value } : l)))}
                  >
                    <SelectTrigger aria-label={lang === "ar" ? "الوحدة" : "Unit"}><SelectValue placeholder={lang === "ar" ? "الوحدة" : "Unit"} /></SelectTrigger>
                    <SelectContent>
                      {compatibleUnits(stockLine(line).item?.unit ?? line.unit).map((u) => (
                        <SelectItem key={u} value={u}>{unitLabel(u)}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Input
                    placeholder={lang === "ar" ? "إجمالي السطر" : "Line total"}
                    inputMode="decimal"
                    value={line.line_total}
                    onChange={(e) => setLines(lines.map((l, i) => (i === index ? { ...l, line_total: e.target.value } : l)))}
                  />
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={lines.length === 1}
                    onClick={() => setLines(lines.filter((_, i) => i !== index))}
                  >
                    ✕
                  </Button>
                </div>
                {(() => {
                  const sl = stockLine(line);
                  if (!sl.item || sl.qty <= 0 || sl.total <= 0) return null;
                  const prev = Number(sl.item.cost_per_unit ?? 0);
                  const jump = prev > 0 && sl.unitCost > prev * 10;
                  return (
                    <p className={jump ? "text-xs font-semibold text-destructive" : "text-xs text-muted-foreground"}>
                      {lang === "ar"
                        ? `= ${formatMoney(sl.unitCost, currency, lang)} لكل ${unitLabel(sl.item.unit)} (${sl.qty} ${unitLabel(sl.item.unit)} داخلين المخزن)${jump ? " — أعلى من المعتاد جداً، راجع الوحدة" : ""}`
                        : `= ${formatMoney(sl.unitCost, currency, lang)} per ${sl.item.unit} (${sl.qty} ${sl.item.unit} into stock)${jump ? " — unusually high, check the unit" : ""}`}
                    </p>
                  );
                })()}
                </div>
              ))}
              <Button
                variant="secondary"
                size="sm"
                onClick={() => setLines([...lines, EMPTY_LINE])}
              >
                {t("purch.addLine")}
              </Button>
            </div>

            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label>{t("pos.discount")}</Label>
                <Input
                  className="mt-1"
                  inputMode="decimal"
                  value={discountAmount}
                  onChange={(e) => setDiscountAmount(e.target.value)}
                />
              </div>
            </div>
            <div>
              <Label>{t("common.notes")}</Label>
              <Input className="mt-1" value={notes} onChange={(e) => setNotes(e.target.value)} />
            </div>
            <ChoiceRow<PaymentTerms>
              label="شروط الدفع"
              value={terms}
              onChange={setTerms}
              options={(["cash", "bank", "credit"] as PaymentTerms[]).map((v) => ({ value: v, label: TERMS_LABEL[v] }))}
            />
            {terms === "cash" && (
              <ChoiceRow<PaySource>
                label="مصدر الكاش"
                value={cashSource}
                onChange={setCashSource}
                options={(["treasury", "drawer"] as PaySource[]).map((v) => ({ value: v, label: SOURCE_LABEL[v] }))}
              />
            )}
            {terms === "credit" && (
              <div>
                <Label>دفعة مقدمة من الخزينة (اختياري)</Label>
                <Input
                  className="mt-1"
                  inputMode="decimal"
                  placeholder="0"
                  value={paidNow}
                  onChange={(e) => setPaidNow(e.target.value)}
                />
              </div>
            )}
            <FilePicker file={attachFile} onChange={setAttachFile} />
            <p className="text-sm">
              {t("common.total")}: <strong>{formatMoney(grandTotal, currency, lang)}</strong>
            </p>
            <p className="text-xs text-muted-foreground">{t("purch.receiveHint")}</p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPurchaseDialog(false)}>
              {t("common.cancel")}
            </Button>
            <Button
              disabled={createPurchase.isPending || linesTotal <= 0 || !supplierId}
              onClick={() => createPurchase.mutate()}
            >
              {t("purch.saveReceive")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(cancelTarget)} onOpenChange={(open) => !open && setCancelTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {t("purch.cancelTitle")} — {cancelTarget?.label}
            </DialogTitle>
          </DialogHeader>
          <div className="grid gap-2">
            <Label>{t("orders.reason")}</Label>
            <Input value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} />
            <p className="text-xs text-muted-foreground">{t("purch.cancelHint")}</p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCancelTarget(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={cancelReason.trim().length < 3 || cancelPurchase.isPending}
              onClick={() => cancelPurchase.mutate()}
            >
              {t("orders.confirmCancel")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(payTarget)} onOpenChange={(open) => !open && setPayTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {t("purch.paymentTitle")} — {payTarget?.label}
            </DialogTitle>
          </DialogHeader>
          <div className="grid gap-3">
            <p className="text-sm text-muted-foreground">
              {t("purch.due")}:{" "}
              <strong className="text-foreground">
                {formatMoney(payTarget?.due ?? 0, currency, lang)}
              </strong>
            </p>
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label>{t("purch.paymentAmount")}</Label>
                <Input
                  className="mt-1"
                  inputMode="decimal"
                  value={payAmount}
                  onChange={(e) => setPayAmount(e.target.value)}
                />
              </div>
              <ChoiceRow<PaySource>
                label="مصدر الدفع"
                value={paySource}
                onChange={setPaySource}
                options={(["treasury", "drawer", "bank"] as PaySource[]).map((v) => ({ value: v, label: SOURCE_LABEL[v] }))}
              />
            </div>
            <div>
              <Label>{t("common.date")}</Label>
              <Input
                type="date"
                className="mt-1"
                value={payDate}
                onChange={(e) => setPayDate(e.target.value)}
              />
            </div>
            <div>
              <Label>{t("common.notes")}</Label>
              <Input
                className="mt-1"
                value={payNotes}
                onChange={(e) => setPayNotes(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPayTarget(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              disabled={
                recordPayment.isPending ||
                Number(payAmount || 0) <= 0 ||
                Number(payAmount || 0) > (payTarget?.due ?? 0)
              }
              onClick={() => recordPayment.mutate()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(returnTarget)} onOpenChange={(open) => !open && setReturnTarget(null)}>
        <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>
              {t("purch.returnTitle")} —{" "}
              {returnTarget?.invoice_number ||
                (returnTarget ? formatDate(returnTarget.purchase_date, lang) : "")}
            </DialogTitle>
          </DialogHeader>
          <div className="grid gap-3">
            <div className="flex flex-wrap items-center gap-2">
              <Button
                type="button"
                size="sm"
                variant="secondary"
                onClick={() => {
                  const next: Record<string, string> = {};
                  for (const line of returnTarget?.purchase_items ?? []) {
                    const left = remainingQty(line);
                    if (left > 0) next[line.id] = String(left);
                  }
                  setReturnQty(next);
                }}
              >
                {t("purch.returnAll")}
              </Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setReturnQty({})}>
                {t("purch.returnClear")}
              </Button>
            </div>
            <div className="space-y-2 rounded-lg border border-border p-3">
              {(returnTarget?.purchase_items ?? []).map((line) => {
                const left = remainingQty(line);
                return (
                  <div
                    key={line.id}
                    className="grid items-center gap-2 sm:grid-cols-[1fr_auto_110px]"
                  >
                    <span className="text-sm font-medium">{itemName(line.inventory_items)}</span>
                    <span className="text-xs text-muted-foreground">
                      {t("purch.remainingQty")}: {left} {line.inventory_items?.unit ?? ""}
                    </span>
                    <Input
                      inputMode="decimal"
                      placeholder={t("purch.returnQty")}
                      disabled={left <= 0}
                      value={returnQty[line.id] ?? ""}
                      onChange={(e) => {
                        const raw = e.target.value;
                        const capped = Number(raw) > left ? String(left) : raw;
                        setReturnQty({ ...returnQty, [line.id]: capped });
                      }}
                    />
                  </div>
                );
              })}
              <div className="flex items-center justify-between border-t border-border pt-2 text-sm font-semibold">
                <span>{t("purch.returnValue")}</span>
                <span>
                  {formatMoney(
                    (returnTarget?.purchase_items ?? []).reduce((sum, line) => {
                      const qty = Number(returnQty[line.id] || 0);
                      return sum + qty * Number(line.unit_cost || 0);
                    }, 0),
                    currency,
                    lang,
                  )}
                </span>
              </div>
            </div>
            <div>
              <Label>{t("purch.refundMode")}</Label>
              <Select
                value={refundMode}
                onValueChange={(value) => setRefundMode(value as "reduce_due" | "cash")}
              >
                <SelectTrigger className="mt-1">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="reduce_due">{t("purch.refundReduceDue")}</SelectItem>
                  <SelectItem value="cash">{t("purch.refundCash")}</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div>
              <Label>{t("orders.reason")}</Label>
              <Input
                className="mt-1"
                value={returnReason}
                onChange={(e) => setReturnReason(e.target.value)}
              />
            </div>
            <p className="text-xs text-muted-foreground">{t("purch.returnPartialHint")}</p>
            <p className="text-xs text-muted-foreground">{t("purch.returnHint")}</p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setReturnTarget(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              disabled={
                returnItems.isPending ||
                returnReason.trim().length < 3 ||
                !Object.values(returnQty).some((q) => Number(q) > 0)
              }
              onClick={() => returnItems.mutate()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
