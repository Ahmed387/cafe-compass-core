import { downloadCsv, stampedName } from "@/lib/csv";

type ExportOrder = {
  order_number: string;
  created_at: string;
  shift_id: string | null;
  status: string;
  subtotal: number | string;
  total: number | string;
  order_payments?: Array<{ method_key: string; amount: number | string }> | null;
  order_refunds?: Array<{ amount: number | string; status: string }> | null;
};

const refunded = (o: ExportOrder) =>
  (o.order_refunds ?? [])
    .filter((r) => r.status === "active")
    .reduce((acc, r) => acc + Number(r.amount), 0);

/** Downloads the invoice ledger (all filtered rows, not just the visible page). */
export function exportOrdersCsv(rows: ExportOrder[]) {
  downloadCsv(
    rows,
    [
      { header: "Invoice Number", value: (o) => o.order_number },
      { header: "Date & Time", value: (o) => o.created_at },
      { header: "Shift ID", value: (o) => o.shift_id },
      {
        header: "Payment Method",
        value: (o) =>
          (o.order_payments ?? []).map((p) => `${p.method_key}:${Number(p.amount)}`).join(" | "),
      },
      { header: "Subtotal", value: (o) => Number(o.subtotal) },
      { header: "Total", value: (o) => Number(o.total) },
      { header: "Refunded Amount", value: (o) => refunded(o) },
      { header: "Net Total", value: (o) => Math.max(0, Number(o.total) - refunded(o)) },
      { header: "Final Status", value: (o) => o.status },
    ],
    stampedName("orders-ledger", "csv"),
  );
}
