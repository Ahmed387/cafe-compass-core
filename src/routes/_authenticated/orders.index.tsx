import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Download, FileSpreadsheet, Loader2 } from "lucide-react";
import { exportOrdersCsv } from "@/modules/operations/orders-csv";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { CustomerProfileDialog } from "@/components/customers/CustomerProfileDialog";
import { OrderDetailsDialog, type OrderDetails } from "@/components/orders/OrderDetailsDialog";
import { PreparedDisposition, useDisposition } from "@/components/orders/PreparedDisposition";
import { Pagination } from "@/components/shared";
import { ShortageBearerCell } from "@/modules/operations/ShortageBearerCell";
import { KpiCard, KpiDetailRows, KpiGrid } from "@/components/shared/KpiCard";
import { emptyTenders, normalizeTender, type TenderKey, netInvoiceTotal, saleRefundTotal } from "@/core/finance/formulas";
import { EditClosingCashButton } from "@/modules/operations/EditClosingCashButton";

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
import { UnifiedSearchFilter } from "@/modules/shell/UnifiedSearchFilter";
import { Label } from "@/components/ui/label";
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
import { formatDateTime, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence } from "@/lib/receipt";
import {
  filterShifts,
  ShiftFilterBar,
  ShiftLedgerKpis,
  ShiftShortageBreakdown,
  type ShiftFilter,
} from "@/modules/operations/ShiftLedgerKpis";
import {
  exportClosedShiftWorkbook,
  type ShiftInvoiceLineExport,
  type ShiftSummaryExport,
} from "@/lib/shift-excel";

export const Route = createFileRoute("/_authenticated/orders/")({
  head: () => ({
    meta: [
      { title: "Orders & shifts — 20s Coffee" },
      {
        name: "description",
        content: "Review sales orders, payments and cash shift reconciliation for 20s Coffee.",
      },
      { property: "og:title", content: "Orders & shifts — 20s Coffee" },
      { property: "og:description", content: "Sales history, cancellations and cash variance." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  validateSearch: (search: Record<string, unknown>) => ({
    tab: search["tab"] === "shifts" ? ("shifts" as const) : undefined,
    orderId: typeof search["orderId"] === "string" ? search["orderId"] : undefined,
  }),
  component: OrdersPage,
});

const PAGE_SIZE = 25;

function isoDay(offsetDays: number) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

function nextDayIso(day: string) {
  const d = new Date(`${day}T00:00:00.000Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString();
}

function searchDay(value: string) {
  const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(value);
  const local = /^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/.exec(value);
  const parts = iso ? [iso[1], iso[2], iso[3]] : local ? [local[3], local[2], local[1]] : null;
  if (!parts?.[0] || !parts[1] || !parts[2]) return null;
  return `${parts[0]}-${parts[1].padStart(2, "0")}-${parts[2].padStart(2, "0")}`;
}

type OrdersSummary = {
  count: number;
  sales: number;
  cancelled: number;
  refunded: number;
  pending: number;
  today_count: number;
  today_sales: number;
};

function OrdersPage() {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const navigate = useNavigate();
  const search = Route.useSearch();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  const [cancelOrder, setCancelOrder] = useState<{ id: string; number: string } | null>(null);
  const cancelDisposition = useDisposition();
  const [reason, setReason] = useState("");
  const [detailsOrder, setDetailsOrder] = useState<OrderDetails | null>(null);
  const [profileCustomer, setProfileCustomer] = useState<{
    id: string;
    name: string | null;
  } | null>(null);
  const [from, setFrom] = useState(isoDay(-29));
  const [to, setTo] = useState(isoDay(0));
  const [status, setStatus] = useState("all");
  const [q, setQ] = useState("");
  const [debouncedQ, setDebouncedQ] = useState("");
  const [page, setPage] = useState(0);
  const [exportingShiftId, setExportingShiftId] = useState<string | null>(null);
  const [shiftFilter, setShiftFilter] = useState<ShiftFilter>({ number: "", from: "", to: "" });
  const [exportingCsv, setExportingCsv] = useState(false);
  const [orderType, setOrderType] = useState("all");
  const [payMethod, setPayMethod] = useState("all");
  const [shiftNo, setShiftNo] = useState("");

  const canView = can("pos.view") || can("reports.sales");
  // Cashier-only accounts see just their own open shift (also enforced in the database).
  const cashierOnly =
    (me?.roleNames.includes("Cashier") ?? false) &&
    !(me?.roleNames.some((role) => ["Super Admin", "Manager", "Partner"].includes(role)) ?? false);
  const myShift = useQuery({
    queryKey: ["my-open-shift", currentBranchId, me?.profile.id],
    enabled: cashierOnly && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select("id")
        .eq("branch_id", currentBranchId!)
        .eq("status", "open")
        .order("opened_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (error) throw error;
      return data?.id ?? null;
    },
  });
  const myShiftId = myShift.data ?? null;

  // One query builder for the visible page and the CSV export (same filters).
  async function fetchOrders(offset: number, limit: number) {
    const branchId = currentBranchId;
    if (!branchId) throw new Error("Missing branch");
    let query = supabase
      .from("orders")
      .select(
        "id, order_number, order_type, status, subtotal, discount_amount, tax_amount, total, created_at, cancel_reason, customer_id, customer_name, customer_phone, notes, shift_id, user_profiles!orders_created_by_fkey(display_name, first_name, last_name), order_items(id, product_name, size_name, unit_price, quantity, line_total, status, void_reason, notes, order_item_modifiers(name)), order_payments(method_key, amount), order_refunds(amount, status, origin), partner_tab_orders(id, total_amount, is_settled)",
        { count: "exact" },
      )
      .eq("branch_id", branchId)
      .gte("created_at", `${from}T00:00:00.000Z`)
      .lt("created_at", nextDayIso(to))
      .order("created_at", { ascending: false })
      .range(offset, offset + limit - 1);
    if (cashierOnly) {
      if (!myShiftId) return { rows: [], total: 0 };
      query = query.eq("shift_id", myShiftId);
    }
    if (orderType !== "all") query = query.eq("order_type", orderType as "dine_in");
    if (payMethod !== "all") {
      const { data: paid, error: payError } = await supabase
        .from("order_payments")
        .select("order_id")
        .eq("method_key", payMethod)
        .gte("created_at", `${from}T00:00:00.000Z`)
        .lt("created_at", nextDayIso(to))
        .limit(5000);
      if (payError) throw payError;
      const ids = [...new Set((paid ?? []).map((p) => p.order_id))];
      if (ids.length === 0) return { rows: [], total: 0 };
      query = query.in("id", ids);
    }
    if (shiftNo) {
      const shiftId = Object.entries(shiftNumbers.data ?? {}).find(([, n]) => String(n) === shiftNo)?.[0];
      if (!shiftId) return { rows: [], total: 0 };
      query = query.eq("shift_id", shiftId);
    }
    if (status === "refunded") {
      query = query.in("status", ["refunded", "partially_refunded"]);
    } else if (status !== "all") {
      query = query.eq("status", status as "completed");
    }
    // Smart search: invoice number, customer, phone, cashier, items or a date (YYYY-MM-DD).
    const s = debouncedQ.trim();
    if (s) {
      const day = searchDay(s);
      if (day) {
        query = query.gte("created_at", `${day}T00:00:00.000Z`).lt("created_at", nextDayIso(day));
      } else {
        const safe = s.replace(/[%,()]/g, "").trim();
        if (safe) {
          const [directResult, itemResult, cashierResult] = await Promise.all([
            supabase
              .from("orders")
              .select("id")
              .eq("branch_id", branchId)
              .or(
                `order_number.ilike.%${safe}%,customer_name.ilike.%${safe}%,customer_phone.ilike.%${safe}%`,
              )
              .limit(500),
            supabase
              .from("order_items")
              .select("order_id, orders!inner(branch_id)")
              .eq("orders.branch_id", branchId)
              .ilike("product_name", `%${safe}%`)
              .limit(500),
            supabase
              .from("user_profiles")
              .select("id")
              .or(
                `display_name.ilike.%${safe}%,first_name.ilike.%${safe}%,last_name.ilike.%${safe}%`,
              )
              .limit(100),
          ]);
          if (directResult.error) throw directResult.error;
          if (itemResult.error) throw itemResult.error;
          if (cashierResult.error) throw cashierResult.error;

          const cashierIds = (cashierResult.data ?? []).map((profile) => profile.id);
          const cashierOrders = cashierIds.length
            ? await supabase
                .from("orders")
                .select("id")
                .eq("branch_id", branchId)
                .in("created_by", cashierIds)
                .limit(500)
            : { data: [], error: null };
          if (cashierOrders.error) throw cashierOrders.error;

          const ids = Array.from(
            new Set([
              ...(directResult.data ?? []).map((row) => row.id),
              ...(itemResult.data ?? []).map((row) => row.order_id),
              ...(cashierOrders.data ?? []).map((row) => row.id),
            ]),
          );
          if (ids.length === 0) return { rows: [], total: 0 };
          query = query.in("id", ids);
        }
      }
    }
    const { data, error, count } = await query;
    if (error) throw error;
    return { rows: data ?? [], total: count ?? 0 };
  }

  // Sequential shift numbering per branch keeps drawer traceability on every order row.
  const shiftNumbers = useQuery({
    queryKey: ["shift-sequence", currentBranchId],
    enabled: canView && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select("id")
        .eq("branch_id", currentBranchId!)
        .order("opened_at", { ascending: true })
        .limit(1000);
      if (error) throw error;
      const map: Record<string, number> = {};
      (data ?? []).forEach((row, index) => {
        map[row.id] = index + 1;
      });
      return map;
    },
  });

  // Server-side page: only the visible 25 rows travel to the browser.
  const orders = useQuery({
    queryKey: ["orders", currentBranchId, from, to, status, page, debouncedQ, orderType, shiftNo, payMethod, myShiftId],
    enabled: canView && Boolean(currentBranchId) && (!shiftNo || Boolean(shiftNumbers.data)),
    queryFn: () => fetchOrders(page * PAGE_SIZE, PAGE_SIZE),
  });

  // Summary records follow every active filter and power both totals and exact drill-down lists.
  const periodDetails = useQuery({
    queryKey: ["orders-period-details", currentBranchId, from, to, status, debouncedQ, orderType, shiftNo, payMethod, myShiftId],
    enabled: canView && Boolean(currentBranchId) && (!shiftNo || Boolean(shiftNumbers.data)),
    queryFn: async () => {
      // Totals are aggregated in the database (no row cap); only drill-down rows are sampled.
      const shiftId = shiftNo
        ? Object.entries(shiftNumbers.data ?? {}).find(([, n]) => String(n) === shiftNo)?.[0] ?? null
        : cashierOnly
          ? myShiftId ?? null
          : null;
      const [agg, list] = await Promise.all([
        (cashierOnly && !myShiftId) || (shiftNo && !shiftId)
          ? Promise.resolve({ data: null, error: null })
          : supabase.rpc("orders_period_summary", {
              _branch_id: currentBranchId!,
              _from: from,
              _to: to,
              _status: status,
              _order_type: orderType,
              _pay_method: payMethod,
              _shift_id: shiftId ?? undefined,
              _search: debouncedQ.trim() || undefined,
            }),
        fetchOrders(0, 500),
      ]);
      if (agg.error) throw agg.error;
      const raw = (agg.data ?? {}) as {
        count?: number; sales?: number; cancelled?: number; refunded?: number; pending?: number;
        tenders?: Partial<Record<TenderKey, number>>; tenderCounts?: Partial<Record<TenderKey, number>>;
      };
      const acc = {
        count: Number(raw.count ?? 0),
        sales: Number(raw.sales ?? 0),
        cancelled: Number(raw.cancelled ?? 0),
        refunded: Number(raw.refunded ?? 0),
        pending: Number(raw.pending ?? 0),
        tenders: { ...emptyTenders(), ...Object.fromEntries(Object.entries(raw.tenders ?? {}).map(([k, v]) => [k, Number(v)])) },
        tenderCounts: { ...emptyTenders(), ...Object.fromEntries(Object.entries(raw.tenderCounts ?? {}).map(([k, v]) => [k, Number(v)])) },
      };
      return { summary: acc, rows: list.rows };
    },
  });

  const deepLinkedOrder = useQuery({
    queryKey: ["order-deep-link", search.orderId],
    enabled: canView && Boolean(search.orderId),
    queryFn: async () => {
      if (!search.orderId) return null;
      const { data, error } = await supabase
        .from("orders")
        .select(
          "id, order_number, order_type, status, subtotal, discount_amount, tax_amount, total, created_at, customer_name, customer_phone, user_profiles!orders_created_by_fkey(display_name, first_name, last_name), order_items(id, product_name, size_name, unit_price, quantity, line_total, status, void_reason, notes, order_item_modifiers(name)), order_payments(method_key, amount)",
        )
        .eq("id", search.orderId)
        .maybeSingle();
      if (error) throw error;
      return data as unknown as OrderDetails | null;
    },
  });

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setDebouncedQ(q);
      setPage(0);
    }, 300);
    return () => window.clearTimeout(timer);
  }, [q]);

  useEffect(() => {
    if (deepLinkedOrder.data) setDetailsOrder(deepLinkedOrder.data);
  }, [deepLinkedOrder.data]);

  // Totals come from the server over the whole filtered range, never from the visible page.
  const summary = useQuery({
    queryKey: ["orders-summary", currentBranchId, from, to, status],
    enabled: canView && Boolean(currentBranchId) && !cashierOnly,
    queryFn: async () => {
      const branchId = currentBranchId;
      if (!branchId) throw new Error("Missing branch");
      // _order_type picks the full summary; with only (_from, _to, _branch_id) the API
      // sees two versions with the same parameter names and refuses the call.
      const { data, error } = await supabase.rpc("orders_period_summary", {
        _from: from,
        _to: to,
        _branch_id: branchId,
        _status: status,
        _order_type: "all",
      });
      if (error) throw error;
      return data as unknown as OrdersSummary;
    },
  });

  const shifts = useQuery({
    queryKey: ["shifts", currentBranchId],
    enabled: can("shifts.view") && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select(
          "id, branch_id, status, opening_cash, closing_cash, expected_cash, variance, shortage_resolution, opened_at, closed_at, notes, branches(name), user_profiles!shifts_user_id_fkey(display_name, first_name)",
        )
        .eq("branch_id", currentBranchId!)
        .order("opened_at", { ascending: false })
        .limit(1000);
      if (error) throw error;
      return data ?? [];
    },
  });

  const visibleShifts = filterShifts(
    (shifts.data ?? []).filter((row) => !cashierOnly || row.id === myShiftId),
    shiftNumbers.data ?? {},
    shiftFilter,
  );

  const SHIFT_PAGE = 15;
  const [shiftPage, setShiftPage] = useState(0);
  const shiftPageMax = Math.max(0, Math.ceil(visibleShifts.length / SHIFT_PAGE) - 1);
  const pagedShifts = visibleShifts.slice(Math.min(shiftPage, shiftPageMax) * SHIFT_PAGE, (Math.min(shiftPage, shiftPageMax) + 1) * SHIFT_PAGE);

  const canExportShifts =
    me?.roleNames.some((role) => ["Super Admin", "Manager", "Partner"].includes(role)) ?? false;

  const exportShift = async (shift: NonNullable<typeof shifts.data>[number]) => {
    if (shift.status !== "closed" || !canExportShifts || exportingShiftId) return;
    setExportingShiftId(shift.id);
    const loadingToast = toast.loading(
      lang === "ar" ? "جاري إعداد شيت الوردية..." : "Preparing shift workbook...",
    );
    try {
      const [
        { data: shiftOrders, error: ordersError },
        { data: shiftExpenses, error: expensesError },
      ] = await Promise.all([
        supabase
          .from("orders")
          .select(
            "id, order_number, status, subtotal, discount_amount, total, notes, cancel_reason, created_at, order_items(id, product_id, product_name, size_name, unit_price, quantity, line_total, status, void_reason, notes, products(categories(name, name_ar)), order_item_modifiers(name, price_delta)), order_payments(method_key, amount), order_refunds(order_item_id, amount, method_key, reason, status, origin)",
          )
          .eq("shift_id", shift.id)
          .order("created_at", { ascending: true }),
        supabase
          .from("expenses")
          .select("amount")
          .eq("branch_id", shift.branch_id)
          .eq("status", "active")
          .eq("payment_method", "cash")
          .gte("created_at", shift.opened_at)
          .lte("created_at", shift.closed_at ?? new Date().toISOString()),
      ]);
      if (ordersError) throw ordersError;
      if (expensesError) throw expensesError;

      const orderRows = shiftOrders ?? [];
      const activeRefunds = orderRows.flatMap((order) =>
        (order.order_refunds ?? []).filter((refund) => refund.status === "active"),
      );
      const cashSales = orderRows
        .filter((order) => order.status !== "cancelled")
        .flatMap((order) => order.order_payments ?? [])
        .filter((payment) => payment.method_key.toLowerCase() === "cash")
        .reduce((sum, payment) => sum + Number(payment.amount), 0);
      const cardSales = orderRows
        .filter((order) => order.status !== "cancelled")
        .flatMap((order) => order.order_payments ?? [])
        .filter((payment) => payment.method_key.toLowerCase() !== "cash")
        .reduce((sum, payment) => sum + Number(payment.amount), 0);
      const refundTotal = activeRefunds.reduce((sum, refund) => sum + Number(refund.amount), 0);
      const pettyCashExpenses = (shiftExpenses ?? []).reduce(
        (sum, expense) => sum + Number(expense.amount),
        0,
      );
      const profile = shift.user_profiles as unknown as {
        display_name: string | null;
        first_name: string;
      } | null;
      const branch = shift.branches as unknown as { name: string } | null;
      const summary: ShiftSummaryExport = {
        shiftNumber: shiftNumbers.data?.[shift.id] ?? 0,
        cashier: profile?.display_name || profile?.first_name || "—",
        branch: branch?.name ?? "—",
        fileDate: shift.opened_at.slice(0, 10),
        openedAt: formatDateTime(shift.opened_at, "ar"),
        closedAt: formatDateTime(shift.closed_at, "ar"),
        openingCash: Number(shift.opening_cash),
        cashSales,
        cardSales,
        pettyCashExpenses,
        expectedCash: Number(shift.expected_cash ?? 0),
        actualCash: Number(shift.closing_cash ?? 0),
        variance: Number(shift.variance ?? 0),
        invoiceCount: orderRows.length,
        completedCount: orderRows.filter((order) => order.status === "completed").length,
        refundedCount: orderRows.filter((order) =>
          ["refunded", "partially_refunded"].includes(order.status),
        ).length,
        refundTotal,
        currency,
      };

      const detailLines: ShiftInvoiceLineExport[] = orderRows.flatMap((order) => {
        const payments = (order.order_payments ?? []).map((payment) =>
          payment.method_key.toLowerCase() === "cash" ? "كاش" : "فيزا / إلكتروني",
        );
        const paymentMethod = [...new Set(payments)].join(" + ") || "—";
        const refundReasons = (order.order_refunds ?? [])
          .filter((refund) => refund.status === "active" && refund.reason)
          .map((refund) => refund.reason)
          .join("؛ ");
        const statusLabel =
          order.status === "completed"
            ? "مكتملة"
            : order.status === "refunded"
              ? "مرتجعة بالكامل"
              : order.status === "partially_refunded"
                ? "مرتجعة جزئياً"
                : order.status === "cancelled"
                  ? "ملغاة"
                  : "معلقة";
        const items = order.order_items ?? [];
        const activeSubtotal = items.reduce(
          (sum, item) => sum + (item.status === "voided" ? 0 : Number(item.line_total)),
          0,
        );
        return items.map((item) => {
          const itemRefund = (order.order_refunds ?? [])
            .filter((refund) => refund.status === "active" && refund.order_item_id === item.id)
            .reduce((sum, refund) => sum + Number(refund.amount), 0);
          const fullyRefunded = order.status === "refunded";
          const itemWasRefunded = fullyRefunded || itemRefund > 0;
          const orderHasRefund = ["refunded", "partially_refunded"].includes(order.status);
          const cancelled = order.status === "cancelled" || item.status === "voided";
          const grossLine = Number(item.line_total);
          const exportedLine = fullyRefunded
            ? -grossLine
            : itemRefund > 0
              ? -itemRefund
              : cancelled
                ? 0
                : grossLine;
          const allocatedDiscount =
            activeSubtotal > 0
              ? (Number(order.discount_amount ?? 0) * grossLine) / activeSubtotal
              : 0;
          const product = item.products as unknown as {
            categories: { name: string; name_ar: string | null } | null;
          } | null;
          const modifiers = (item.order_item_modifiers ?? [])
            .map(
              (modifier) =>
                `${modifier.name} (+${Number(modifier.price_delta).toFixed(2)} ${currency})`,
            )
            .join("، ");
          return {
            invoiceNumber: invoiceSequence(order.order_number),
            invoiceTime: formatDateTime(order.created_at, "ar"),
            paymentMethod,
            status: item.status === "voided" ? "بند ملغي" : statusLabel,
            productName: [item.product_name, item.size_name].filter(Boolean).join(" — "),
            category: product?.categories?.name_ar || product?.categories?.name || "—",
            modifiers: modifiers || "—",
            quantity: Number(item.quantity),
            unitPrice: itemWasRefunded ? -Number(item.unit_price) : Number(item.unit_price),
            lineTotal: exportedLine,
            discount: itemWasRefunded ? -allocatedDiscount : allocatedDiscount,
            grandTotal:
              Number(order.total) -
              (order.order_refunds ?? [])
                .filter((refund) => refund.status === "active")
                .reduce((sum, refund) => sum + Number(refund.amount), 0),
            notes:
              [item.notes, item.void_reason, order.notes, order.cancel_reason, refundReasons]
                .filter(Boolean)
                .join(" — ") || "—",
            isRefunded: orderHasRefund,
            isCancelled: cancelled,
          };
        });
      });

      await exportClosedShiftWorkbook(summary, detailLines);
      toast.success(lang === "ar" ? "تم تنزيل شيت الوردية." : "Shift workbook downloaded.");
    } catch (error) {
      toast.error(friendlyError(error, lang));
    } finally {
      toast.dismiss(loadingToast);
      setExportingShiftId(null);
    }
  };

  const cancel = useMutation({
    mutationFn: async () => {
      if (!cancelOrder) throw new Error("Missing order");
      const { error } = await supabase.rpc("cancel_pos_order", {
        _order_id: cancelOrder.id,
        _reason: reason.trim(),
        ...cancelDisposition.args,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setCancelOrder(null);
      setReason("");
      await queryClient.invalidateQueries({ queryKey: ["orders"] });
      await queryClient.invalidateQueries({ queryKey: ["orders-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["branch-stock"] });
      toast.success(t("orders.cancelled"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const deliver = useMutation({
    mutationFn: async (orderId: string) => {
      const { error } = await supabase.rpc("mark_order_delivered", { _order_id: orderId });
      if (error) throw error;
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["orders"] });
      await queryClient.invalidateQueries({ queryKey: ["orders-summary"] });
      toast.success(t("orders.deliverDone"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const typeLabel = (value: string) =>
    value === "dine_in"
      ? t("pos.dineIn")
      : value === "delivery"
        ? t("pos.delivery")
        : t("pos.takeaway");

  const rows = orders.data?.rows ?? [];
  const total = orders.data?.total ?? 0;
  const salesToday = summary.data?.today_sales ?? 0;
  const ordersToday = summary.data?.today_count ?? 0;
  const ar = lang === "ar";
  const filtersActive = Boolean(debouncedQ.trim() || orderType !== "all" || payMethod !== "all" || shiftNo || status !== "all");
  const detailOrders = periodDetails.data?.rows ?? [];
  const kpi = periodDetails.data?.summary;
  const activeTab = search.tab === "shifts" && can("shifts.view") ? "shifts" : "orders";
  const orderDetailRows = (predicate: (order: (typeof detailOrders)[number]) => boolean = () => true) => (
    <KpiDetailRows
      empty={ar ? "لا توجد فواتير ضمن النطاق." : "No invoices in this range."}
      rows={detailOrders.filter(predicate).map((order) => {
        return {
          label: `#${invoiceSequence(order.order_number)}`,
          hint: `${formatDateTime(order.created_at, lang)} · ${(order.order_payments ?? []).map((payment) => payment.method_key).join(" + ") || "—"}`,
          value: formatMoney(netInvoiceTotal(order, order.order_refunds), currency, lang),
        };
      })}
    />
  );
  const paymentDetailRows = (key: TenderKey) => (
    <KpiDetailRows
      empty={ar ? "لا توجد عمليات بهذه الطريقة." : "No payments by this method."}
      rows={detailOrders.flatMap((order) =>
        (order.order_payments ?? [])
          .filter((payment) => normalizeTender(payment.method_key) === key)
          .map((payment) => ({
            label: `#${invoiceSequence(order.order_number)}`,
            hint: formatDateTime(order.created_at, lang),
            value: formatMoney(Number(payment.amount), currency, lang),
          })),
      )}
    />
  );
  const tenderLabels: Record<TenderKey, string> = {
    cash: ar ? "كاش" : "Cash",
    instapay: ar ? "إنستاباي" : "InstaPay",
    wallet: ar ? "المحافظ / فودافون كاش" : "Wallets",
    visa: ar ? "فيزا" : "Visa",
    partner_tab: ar ? "حساب الشريك" : "Partner account",
  };
  const tenderKeys: TenderKey[] = ["cash", "instapay", "wallet", "visa", "partner_tab"];

  return (
    <div>
      <PageHeader
        title={t("orders.title")}
        description={cashierOnly ? (ar ? (myShiftId ? "تعرض هذه الصفحة ورديتك المفتوحة وطلباتها فقط." : "لا توجد وردية مفتوحة لك الآن — افتح وردية من شاشة الكاشير.") : (myShiftId ? "Showing only your open shift and its orders." : "You have no open shift — open one from the cashier screen.")) : `${t("orders.salesToday")}: ${formatMoney(salesToday, currency, lang)} · ${ordersToday} ${t("orders.count")}`}
      />


      <Tabs
        value={activeTab}
        onValueChange={(value) => {
          navigate({
            to: "/orders",
            search: { tab: value === "shifts" ? "shifts" : undefined, orderId: undefined },
          });
        }}
      >
        <TabsList>
          <TabsTrigger value="orders">{t("orders.tab")}</TabsTrigger>
          {can("shifts.view") && <TabsTrigger value="shifts">{t("orders.shifts")}</TabsTrigger>}
        </TabsList>

        <TabsContent value="orders" className="mt-4 space-y-3">
          <UnifiedSearchFilter
            search={q}
            onSearch={(v) => {
              setQ(v);
              if (!v) setDebouncedQ("");
              setPage(0);
            }}
            placeholder={t("orders.searchPlaceholder")}
            filters={[
              { key: "type", label: ar ? "النوع" : "Type", value: orderType, onChange: (v) => { setOrderType(v); setPage(0); }, options: [
                { value: "all", label: ar ? "كل الأنواع" : "All types" },
                { value: "dine_in", label: ar ? "صالة" : "Dine-in" },
                { value: "takeaway", label: ar ? "تيك أواي" : "Takeaway" },
                { value: "delivery", label: ar ? "توصيل" : "Delivery" },
              ] },
              { key: "pay", label: ar ? "طريقة الدفع" : "Payment", value: payMethod, onChange: (v) => { setPayMethod(v); setPage(0); }, options: [
                { value: "all", label: ar ? "كل طرق الدفع" : "All payments" },
                { value: "cash", label: ar ? "كاش" : "Cash" },
                { value: "visa", label: ar ? "فيزا" : "Visa" },
                { value: "instapay", label: ar ? "إنستاباي" : "InstaPay" },
                { value: "wallet", label: ar ? "محفظة" : "Wallet" },
                { value: "partner_tab", label: ar ? "حساب الشريك" : "Partner tab" },
              ] },
              { key: "status", label: t("common.status"), value: status, onChange: (v) => { setStatus(v); setPage(0); }, options: [
                { value: "all", label: ar ? "كل الحالات" : "All statuses" },
                { value: "pending", label: t("orders.statusPending") },
                { value: "completed", label: t("orders.statusDone") },
                { value: "refunded", label: t("orders.statusRefunded") },
                { value: "cancelled", label: t("orders.statusCancelled") },
              ] },
            ]}
          >
            {!cashierOnly && <Input aria-label={ar ? "رقم الوردية" : "Shift #"} inputMode="numeric" className="h-11 w-24 shrink-0" placeholder={ar ? "وردية #" : "Shift #"} value={shiftNo} onChange={(e) => { setShiftNo(e.target.value.replace(/[^0-9]/g, "")); setPage(0); }} />}
            {!cashierOnly && <Input aria-label={t("range.from")} type="date" className="h-11 w-40 shrink-0" value={from} onChange={(e) => { setFrom(e.target.value); setPage(0); }} />}
            {!cashierOnly && <Input aria-label={t("range.to")} type="date" className="h-11 w-40 shrink-0" value={to} onChange={(e) => { setTo(e.target.value); setPage(0); }} />}
          </UnifiedSearchFilter>
          {!cashierOnly && <section className="space-y-3">
            <KpiCard
              size="master"
              label={ar ? "إجمالي إيرادات الفترة" : "Total period revenue"}
              value={formatMoney(kpi?.sales ?? 0, currency, lang)}
              tone="brand"
              hint={filtersActive ? (ar ? "حسب الفلاتر الحالية" : "Using current filters") : `${kpi?.count ?? 0} ${ar ? "فاتورة" : "invoices"}`}
              formula={ar ? "مجموع إجمالي الفواتير غير الملغاة − المرتجعات النشطة." : "Non-cancelled invoice totals − active refunds."}
              source={ar ? "المصدر: الفواتير والمرتجعات ضمن التاريخ والفلاتر الحالية." : "Source: invoices and refunds in the current date range and filters."}
              details={orderDetailRows((order) => order.status !== "cancelled")}
            />
            <div>
              <h3 className="mb-2 text-xs font-semibold text-muted-foreground">{ar ? "الإيرادات حسب طريقة الدفع" : "Revenue by payment method"}</h3>
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
                {tenderKeys.map((key) => (
                  <KpiCard
                    key={key}
                    label={tenderLabels[key]}
                    value={formatMoney(kpi?.tenders[key] ?? 0, currency, lang)}
                    hint={`${kpi?.tenderCounts[key] ?? 0} ${ar ? "عملية" : "txns"}`}
                    formula={ar ? "مجموع المدفوعات المسجلة بهذه الطريقة." : "Sum of payments recorded using this method."}
                    source={ar ? "المصدر: عمليات دفع الفواتير المطابقة للفلاتر." : "Source: payments on invoices matching the filters."}
                    details={paymentDetailRows(key)}
                  />
                ))}
              </div>
            </div>
            <KpiGrid cols={3} title={ar ? "حالة التشغيل" : "Operational status"}>
              <KpiCard label={ar ? "عدد الأوردرات" : "Orders"} value={kpi?.count ?? 0} formula={ar ? "عدد كل الفواتير المطابقة للفلاتر." : "Count of all invoices matching the filters."} details={orderDetailRows()} />
              <KpiCard label={ar ? "المرتجع" : "Refunded"} value={kpi?.refunded ?? 0} formula={ar ? "الفواتير المرتجعة كليًا أو جزئيًا." : "Fully or partially refunded invoices."} details={orderDetailRows((order) => order.status === "refunded" || order.status === "partially_refunded")} />
              <KpiCard label={ar ? "الملغي" : "Cancelled"} value={kpi?.cancelled ?? 0} tone={(kpi?.cancelled ?? 0) > 0 ? "bad" : undefined} formula={ar ? "الفواتير الملغاة ضمن النطاق." : "Cancelled invoices in the range."} details={orderDetailRows((order) => order.status === "cancelled")} />
            </KpiGrid>
          </section>}
          <div className="flex justify-end">
            <Button
              variant="outline"
              size="sm"
              disabled={exportingCsv || rows.length === 0}
              onClick={async () => {
                setExportingCsv(true);
                try {
                  const all = await fetchOrders(0, 10000);
                  exportOrdersCsv(all.rows);
                  toast.success(lang === "ar" ? `تم تصدير ${all.rows.length} فاتورة` : `Exported ${all.rows.length} invoices`);
                } catch (error) {
                  toast.error(friendlyError(error));
                } finally {
                  setExportingCsv(false);
                }
              }}
            >
              {exportingCsv ? <Loader2 className="size-4 animate-spin" /> : <Download className="size-4" />}
              {lang === "ar" ? "تصدير CSV" : "Export CSV"}
            </Button>
          </div>
          {rows.length === 0 ? (
            <EmptyState message={t("orders.empty")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-20 whitespace-nowrap text-start">#</TableHead>
                    <TableHead className="w-44 whitespace-nowrap text-center">
                      {t("common.date")}
                    </TableHead>
                    <TableHead className="min-w-40 text-start">{t("pos.customer")}</TableHead>
                    <TableHead className="min-w-32 text-start">{t("orders.cashier")}</TableHead>
                    <TableHead className="w-20 whitespace-nowrap text-center">
                      {t("orders.shiftNo")}
                    </TableHead>
                    <TableHead className="w-28 whitespace-nowrap text-center">
                      {t("orders.type")}
                    </TableHead>
                    <TableHead className="min-w-44 text-start">{t("orders.items")}</TableHead>
                    <TableHead className="w-28 whitespace-nowrap text-center">
                      {t("pos.method")}
                    </TableHead>
                    <TableHead className="w-28 whitespace-nowrap text-end">
                      {t("orders.grossTotal")}
                    </TableHead>
                    <TableHead className="w-28 whitespace-nowrap text-end">
                      {t("orders.refundedAmount")}
                    </TableHead>
                    <TableHead className="w-28 whitespace-nowrap text-end">
                      {t("orders.netTotal")}
                    </TableHead>
                    <TableHead className="w-32 whitespace-nowrap text-center">
                      {t("common.status")}
                    </TableHead>
                    <TableHead className="w-56 whitespace-nowrap text-center">
                      {t("common.actions")}
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((order) => {
                    const cashier = order.user_profiles as unknown as {
                      display_name: string | null;
                      first_name: string;
                      last_name: string | null;
                    } | null;
                    const cashierName =
                      cashier?.display_name ||
                      `${cashier?.first_name ?? ""} ${cashier?.last_name ?? ""}`.trim() ||
                      "—";
                    const tabRel = order.partner_tab_orders as unknown as
                      { is_settled: boolean } | Array<{ is_settled: boolean }> | null;
                    const tab = Array.isArray(tabRel) ? tabRel[0] : tabRel;
                    const onPartnerTab = Boolean(tab && !tab.is_settled);
                    // Gross = invoice total before refunds; Net = gross - active refunds.
                    const refundedAmount = saleRefundTotal(order.order_refunds);
                    const netTotal = netInvoiceTotal(order, order.order_refunds);
                    return (
                      <TableRow
                        key={order.id}
                        className="cursor-pointer"
                        onDoubleClick={() => setDetailsOrder(order as unknown as OrderDetails)}
                      >
                        <TableCell className="w-20 whitespace-nowrap text-start font-mono font-bold text-primary">
                          {invoiceSequence(order.order_number)}
                        </TableCell>
                        <TableCell className="w-44 whitespace-nowrap text-center">
                          {formatDateTime(order.created_at, lang)}
                        </TableCell>
                        <TableCell className="min-w-40 text-start">
                          {order.customer_id ? (
                            <button
                              type="button"
                              className="font-medium text-primary underline-offset-4 hover:underline"
                              onClick={(event) => {
                                event.stopPropagation();
                                setProfileCustomer({
                                  id: order.customer_id!,
                                  name: order.customer_name,
                                });
                              }}
                            >
                              {order.customer_name || t("orders.walkInCustomer")}
                            </button>
                          ) : (
                            <span className="text-muted-foreground">
                              {order.customer_name || t("orders.walkInCustomer")}
                            </span>
                          )}
                        </TableCell>
                        <TableCell className="min-w-32 text-start">{cashierName}</TableCell>
                        <TableCell className="w-20 whitespace-nowrap text-center font-mono tabular-nums">
                          {order.shift_id ? (shiftNumbers.data?.[order.shift_id] ?? "—") : "—"}
                        </TableCell>
                        <TableCell className="w-28 whitespace-nowrap text-center">
                          {typeLabel(order.order_type)}
                        </TableCell>
                        <TableCell className="min-w-44 max-w-64 text-start text-xs text-muted-foreground">
                          {order.order_items
                            .map(
                              (item) =>
                                `${item.quantity}× ${item.product_name}${item.size_name ? ` (${item.size_name})` : ""}`,
                            )
                            .join(", ")}
                        </TableCell>
                        <TableCell className="w-28 text-center text-xs">
                          {onPartnerTab
                            ? t("orders.partnerTab")
                            : order.order_payments.map((p) => p.method_key).join(", ")}
                        </TableCell>
                        <TableCell className="w-28 whitespace-nowrap text-end font-mono font-semibold tabular-nums">
                          {formatMoney(order.total, currency, lang)}
                        </TableCell>
                        <TableCell className="w-28 whitespace-nowrap text-end font-mono text-xs tabular-nums">
                          {refundedAmount > 0 ? (
                            <span className="font-medium text-destructive">
                              -{formatMoney(refundedAmount, currency, lang)}
                            </span>
                          ) : (
                            <span className="text-muted-foreground">—</span>
                          )}
                        </TableCell>
                        <TableCell className="w-28 whitespace-nowrap text-end font-mono font-bold tabular-nums text-primary">
                          {formatMoney(netTotal, currency, lang)}
                        </TableCell>
                        <TableCell className="w-36 text-center">
                          <div className="inline-flex flex-col items-center gap-1">
                            <Badge
                              variant="outline"
                              className={
                                order.status === "completed"
                                  ? "border-emerald-300 bg-emerald-50 font-semibold text-emerald-700 dark:border-emerald-300 dark:bg-emerald-950/40 dark:text-emerald-300"
                                  : order.status === "pending"
                                    ? "animate-pulse border-amber-300 bg-amber-50 font-semibold text-amber-800 dark:bg-amber-950/40 dark:text-amber-300"
                                    : order.status === "refunded" ||
                                        order.status === "partially_refunded"
                                      ? "border-rose-300 bg-rose-50 font-semibold text-rose-700 dark:bg-rose-950/40 dark:text-rose-300"
                                      : "border-slate-300 bg-slate-100 font-semibold text-slate-600 dark:bg-slate-800/60 dark:text-slate-300"
                              }
                            >
                              {order.status === "cancelled"
                                ? t("orders.statusCancelled")
                                : order.status === "refunded"
                                  ? t("orders.statusRefunded")
                                  : order.status === "partially_refunded"
                                    ? t("orders.statusPartial")
                                    : order.status === "pending"
                                      ? t("orders.statusPending")
                                      : t("orders.statusDone")}
                            </Badge>
                            {onPartnerTab && (
                              <span className="rounded-md border border-amber-400/60 bg-gradient-to-r from-amber-400/20 to-yellow-500/20 px-2.5 py-1 text-xs font-bold text-amber-900 shadow-sm dark:text-amber-300">
                                {t("orders.partnerTab")}
                              </span>
                            )}
                          </div>
                        </TableCell>
                        <TableCell className="w-56 text-center">
                          <div className="inline-flex flex-wrap justify-center gap-2">
                            <Button
                              size="sm"
                              variant="secondary"
                              onClick={(event) => {
                                event.stopPropagation();
                                setDetailsOrder(order as unknown as OrderDetails);
                              }}
                            >
                              {t("orders.details")}
                            </Button>
                            {order.status === "pending" && (
                              <Button
                                size="sm"
                                disabled={deliver.isPending}
                                onClick={(event) => {
                                  event.stopPropagation();
                                  deliver.mutate(order.id);
                                }}
                              >
                                {t("orders.deliver")}
                              </Button>
                            )}
                            {(order.status === "pending" || order.status === "open") &&
                              (can("pos.cancel_order") || can("pos.create_order")) && (
                                <Button
                                  size="sm"
                                  variant="outline"
                                  onClick={(event) => {
                                    event.stopPropagation();
                                    cancelDisposition.reset();
                                    setReason("");
                                    setCancelOrder({ id: order.id, number: order.order_number });
                                  }}
                                >
                                  {t("orders.cancel")}
                                </Button>
                              )}
                            <Button
                              size="sm"
                              variant="ghost"
                              title={t("orders.openInNewTab")}
                              onClick={(event) => {
                                event.stopPropagation();
                                navigate({ to: "/orders/$orderId", params: { orderId: order.id } });
                              }}
                            >
                              {t("orders.invoice")}
                            </Button>
                          </div>
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
              <Pagination
                page={page}
                pageSize={PAGE_SIZE}
                total={total}
                onPage={setPage}
                loading={orders.isFetching}
              />
            </div>
          )}
        </TabsContent>

        {can("shifts.view") && (
          <TabsContent value="shifts" className="mt-4 space-y-4">
            {!cashierOnly && <>
            <ShiftFilterBar value={shiftFilter} onChange={setShiftFilter} lang={lang} />
            <ShiftLedgerKpis
              branchId={currentBranchId}
              shiftIds={visibleShifts.map((row) => row.id)}
              currency={currency}
              lang={lang}
            />
            <ShiftShortageBreakdown
              shifts={visibleShifts.map((row) => ({ id: row.id, status: row.status, variance: row.variance, resolution: row.shortage_resolution }))}
              numbers={shiftNumbers.data ?? {}}
              currency={currency}
              lang={lang}
            />
            </>}
            {visibleShifts.length === 0 ? (
              <EmptyState message={t("orders.noShifts")} />
            ) : (
              <div className="overflow-x-auto rounded-lg border border-border bg-card">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="min-w-40 text-start">{t("audit.user")}</TableHead>
                      <TableHead className="w-44 whitespace-nowrap text-center">
                        {t("orders.openedAt")}
                      </TableHead>
                      <TableHead className="w-44 whitespace-nowrap text-center">
                        {t("orders.closedAt")}
                      </TableHead>
                      <TableHead className="w-36 whitespace-nowrap text-end">
                        {t("pos.openingCash")}
                      </TableHead>
                      <TableHead className="w-36 whitespace-nowrap text-end">
                        {t("orders.expectedCash")}
                      </TableHead>
                      <TableHead className="w-36 whitespace-nowrap text-end">
                        {t("pos.closingCash")}
                      </TableHead>
                      <TableHead className="w-36 whitespace-nowrap text-end">
                        {t("orders.variance")}
                      </TableHead>
                      <TableHead className="w-32 whitespace-nowrap text-end">
                        {lang === "ar" ? "قيمة العجز" : "Shortage"}
                      </TableHead>
                      <TableHead className="w-40 whitespace-nowrap text-center">
                        {lang === "ar" ? "المسؤول عن التحمل" : "Borne by"}
                      </TableHead>
                      <TableHead className="w-32 whitespace-nowrap text-center">
                        {t("common.status")}
                      </TableHead>
                      {canExportShifts && (
                        <TableHead className="w-56 whitespace-nowrap text-center">
                          {t("common.actions")}
                        </TableHead>
                      )}
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {pagedShifts.map((row) => {
                      const profile = row.user_profiles as unknown as {
                        display_name: string | null;
                        first_name: string;
                      } | null;
                      const variance = row.variance === null ? null : Number(row.variance);
                      return (
                        <TableRow key={row.id}>
                          <TableCell className="min-w-40 font-medium">
                            {profile?.display_name || profile?.first_name || "—"}
                          </TableCell>
                          <TableCell className="w-44 whitespace-nowrap text-center">
                            {formatDateTime(row.opened_at, lang)}
                          </TableCell>
                          <TableCell className="w-44 whitespace-nowrap text-center">
                            {formatDateTime(row.closed_at, lang)}
                          </TableCell>
                          <TableCell className="w-36 whitespace-nowrap text-end tabular-nums">
                            {formatMoney(row.opening_cash, currency, lang)}
                          </TableCell>
                          <TableCell className="w-36 whitespace-nowrap text-end tabular-nums">
                            {row.expected_cash === null
                              ? "—"
                              : formatMoney(row.expected_cash, currency, lang)}
                          </TableCell>
                          <TableCell className="w-36 whitespace-nowrap text-end tabular-nums">
                            <span className="inline-flex items-center gap-1">
                              {row.closing_cash === null
                                ? "—"
                                : formatMoney(row.closing_cash, currency, lang)}
                              {row.status === "closed" && canExportShifts && (
                                <EditClosingCashButton shiftId={row.id} current={row.closing_cash} />
                              )}
                            </span>
                          </TableCell>
                          <TableCell
                            className={`w-36 whitespace-nowrap text-end tabular-nums ${
                              variance === null || variance === 0
                                ? ""
                                : "font-medium text-destructive"
                            }`}
                          >
                            {variance === null ? "—" : formatMoney(variance, currency, lang)}
                          </TableCell>
                          <TableCell className="w-32 whitespace-nowrap text-end tabular-nums font-medium text-destructive">
                            {variance !== null && variance < 0 ? formatMoney(-variance, currency, lang) : <span className="text-muted-foreground">—</span>}
                          </TableCell>
                          <TableCell className="w-40 text-center">
                            <ShortageBearerCell
                              shiftId={row.id}
                              shortage={row.status === "closed" && variance !== null && variance < 0 ? -variance : 0}
                              mode={row.shortage_resolution}
                              editable={canExportShifts}
                              lang={lang}
                            />
                          </TableCell>
                          <TableCell className="w-32 text-center">
                            <Badge variant={row.status === "open" ? "secondary" : "outline"}>
                              {row.status === "open" ? t("pos.shiftOpen") : t("orders.shiftClosed")}
                            </Badge>
                          </TableCell>
                          {canExportShifts && (
                            <TableCell className="w-56 text-center">
                              {row.status === "closed" && (
                                <Button
                                  size="sm"
                                  variant="outline"
                                  className="gap-2 whitespace-nowrap"
                                  disabled={Boolean(exportingShiftId)}
                                  onClick={() => void exportShift(row)}
                                >
                                  {exportingShiftId === row.id ? (
                                    <Loader2 className="size-4 animate-spin" />
                                  ) : (
                                    <FileSpreadsheet className="size-4" />
                                  )}
                                  {lang === "ar"
                                    ? "تصدير شيت تفصيلي (Excel)"
                                    : "Export detailed sheet (Excel)"}
                                </Button>
                              )}
                            </TableCell>
                          )}
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
                <div className="border-t border-border p-2">
                  <Pagination page={Math.min(shiftPage, shiftPageMax)} pageSize={SHIFT_PAGE} total={visibleShifts.length} onPage={setShiftPage} />
                </div>
              </div>
            )}
          </TabsContent>
        )}
      </Tabs>

      <Dialog open={Boolean(cancelOrder)} onOpenChange={(open) => !open && setCancelOrder(null)}>
        <DialogContent className="sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>
              {t("orders.cancel")} — #{invoiceSequence(cancelOrder?.number ?? "1")}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <PreparedDisposition
              idPrefix="cancel"
              value={cancelDisposition.value}
              onChange={cancelDisposition.setValue}
            />
            <div className="grid gap-1.5">
              <Label htmlFor="reason" className="text-xs text-muted-foreground">
                {t("orders.reason")}
              </Label>
              <Input id="reason" value={reason} onChange={(e) => setReason(e.target.value)} />
              <p className="text-xs text-muted-foreground">{t("orders.cancelHint")}</p>
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCancelOrder(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={reason.trim().length < 3 || !cancelDisposition.ready || cancel.isPending}
              onClick={() => cancel.mutate()}
            >
              {t("orders.confirmCancel")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <OrderDetailsDialog
        order={detailsOrder}
        onClose={() => {
          setDetailsOrder(null);
          if (search.orderId) {
            navigate({
              to: "/orders",
              search: { tab: search.tab, orderId: undefined },
              replace: true,
            });
          }
        }}
        typeLabel={typeLabel}
      />

      <CustomerProfileDialog
        customerId={profileCustomer?.id ?? null}
        fallbackName={profileCustomer?.name ?? null}
        onClose={() => setProfileCustomer(null)}
      />
    </div>
  );
}
