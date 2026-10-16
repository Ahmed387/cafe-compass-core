import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { EmptyState } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { matches, SmartFilterBar } from "@/modules/shell/SmartFilterBar";

type SupplierReturn = {
  id: string;
  return_date: string;
  refund_mode: string;
  total: number;
  reason: string | null;
  purchases: { invoice_number: string | null; suppliers: { name: string } | null } | null;
  purchase_return_items: {
    id: string;
    quantity: number;
    line_total: number;
    inventory_items: { name: string; name_ar: string | null; unit: string } | null;
  }[];
};

/**
 * Log of returns to suppliers. A return itself is made from the purchase
 * invoice (Purchases tab); this tab lists them all in one place.
 */
export function SupplierReturnsLog() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const [q, setQ] = useState("");
  const supplierReturns = useQuery({
    queryKey: ["supplier-returns"],
    enabled: can("purchases.view"),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("purchase_returns")
        .select(
          "id, return_date, refund_mode, total, reason, purchases(invoice_number, suppliers(name)), purchase_return_items(id, quantity, line_total, inventory_items(name, name_ar, unit))",
        )
        .order("return_date", { ascending: false })
        .limit(200);
      if (error) throw error;
      return (data ?? []) as unknown as SupplierReturn[];
    },
  });
  const sup = (supplierReturns.data ?? []).filter((r) =>
    matches(
      q,
      r.purchases?.suppliers?.name,
      r.purchases?.invoice_number,
      r.reason,
      ...(r.purchase_return_items ?? []).flatMap((l) => [
        l.inventory_items?.name,
        l.inventory_items?.name_ar,
      ]),
    ),
  );
  const total = sup.reduce((s, r) => s + Number(r.total), 0);
  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        {lang === "ar"
          ? "المرتجع للمورد بيتعمل من فاتورة الشراء نفسها (زرار «مرتجع» في تاب المشتريات). هنا السجل كله."
          : "A supplier return is made from its purchase invoice (Return button in Purchases). This is the full log."}{" "}
        <b className="tabular-nums">{formatMoney(total, currency, lang)}</b> ({sup.length})
      </p>
      <SmartFilterBar
        search={q}
        onSearch={setQ}
        placeholder={
          lang === "ar"
            ? "ابحث بالمورد أو الفاتورة أو الصنف أو السبب…"
            : "Search supplier, invoice, item or reason…"
        }
      />
      {sup.length === 0 ? (
        <EmptyState message={t("ret.emptySup")} />
      ) : (
        <div className="overflow-x-auto rounded-xl border border-border/60 bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="text-start">{t("ret.date")}</TableHead>
                <TableHead className="text-start">{t("ret.supplier")}</TableHead>
                <TableHead className="text-start">{t("ret.invoice")}</TableHead>
                <TableHead className="text-start">{t("ret.items")}</TableHead>
                <TableHead className="text-center">{t("ret.mode")}</TableHead>
                <TableHead className="text-end">{t("ret.total")}</TableHead>
                <TableHead className="text-start">{t("ret.reason")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {sup.map((r, idx) => (
                <TableRow key={r.id} className={idx % 2 ? "bg-muted/30" : ""}>
                  <TableCell className="text-start whitespace-nowrap">
                    {formatDate(r.return_date, lang)}
                  </TableCell>
                  <TableCell className="text-start font-medium">
                    {r.purchases?.suppliers?.name ?? "—"}
                  </TableCell>
                  <TableCell className="text-start text-muted-foreground">
                    {r.purchases?.invoice_number ?? "—"}
                  </TableCell>
                  <TableCell className="text-start">
                    <div className="space-y-0.5">
                      {(r.purchase_return_items ?? []).map((line) => (
                        <p key={line.id} className="text-xs">
                          {((lang === "ar" ? line.inventory_items?.name_ar : null) ??
                            line.inventory_items?.name ??
                            "—") + ` × ${line.quantity} ${line.inventory_items?.unit ?? ""}`}
                        </p>
                      ))}
                    </div>
                  </TableCell>
                  <TableCell className="text-center">
                    <Badge variant={r.refund_mode === "cash" ? "default" : "secondary"}>
                      {r.refund_mode === "cash" ? t("ret.mode.cash") : t("ret.mode.credit")}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-end font-semibold tabular-nums">
                    {formatMoney(r.total, currency, lang)}
                  </TableCell>
                  <TableCell className="text-start text-muted-foreground">
                    {r.reason ?? "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
