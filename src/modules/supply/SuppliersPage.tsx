import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { DataTable, Pagination, StatusBadge } from "@/components/shared";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
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

type PurchaseRow = {
  id: string;
  supplier_id: string | null;
  invoice_number: string | null;
  purchase_date: string;
  total: number;
  paid_amount: number;
  returned_amount: number;
  status: string;
  purchase_items: {
    quantity: number;
    unit_cost: number;
    line_total: number;
    inventory_items: { name: string; name_ar: string | null; unit: string } | null;
  }[];
};

type SupplierRow = {
  id: string;
  name: string;
  phone: string | null;
  contact_person: string | null;
  payment_terms: string | null;
  is_active: boolean;
};

export function SuppliersPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const canView = can("suppliers.view") || can("purchases.view") || can("inventory.view");

  const [search, setSearch] = useState("");
  const [openId, setOpenId] = useState<string | null>(null);
  const [invoicePage, setInvoicePage] = useState(0);
  const invoicePageSize = 15;

  const suppliers = useQuery({
    queryKey: ["suppliers-ledger"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("suppliers")
        .select("id, name, phone, contact_person, payment_terms, is_active")
        .order("name");
      if (error) throw error;
      return (data ?? []) as SupplierRow[];
    },
  });

  const purchases = useQuery({
    queryKey: ["suppliers-purchases"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("purchases")
        .select(
          "id, supplier_id, invoice_number, purchase_date, total, paid_amount, returned_amount, status, purchase_items(quantity, unit_cost, line_total, inventory_items(name, name_ar, unit))",
        )
        .neq("status", "cancelled")
        .order("purchase_date", { ascending: false });
      if (error) throw error;
      return (data ?? []) as unknown as PurchaseRow[];
    },
  });

  const rows = useMemo(() => {
    const list = suppliers.data ?? [];
    const all = purchases.data ?? [];
    return list
      .map((s) => {
        const mine = all.filter((p) => p.supplier_id === s.id);
        const purchased = mine.reduce((sum, p) => sum + Number(p.total), 0);
        const returned = mine.reduce((sum, p) => sum + Number(p.returned_amount), 0);
        const paid = mine.reduce((sum, p) => sum + Number(p.paid_amount), 0);
        const due = Math.max(0, purchased - returned - paid);
        return {
          supplier: s,
          invoices: mine,
          purchased,
          returned,
          paid,
          due,
          lastDate: mine[0]?.purchase_date ?? null,
        };
      })
      .filter((r) =>
        search.trim()
          ? `${r.supplier.name} ${r.supplier.phone ?? ""}`
              .toLowerCase()
              .includes(search.trim().toLowerCase())
          : true,
      )
      .sort((a, b) => b.due - a.due || b.purchased - a.purchased);
  }, [suppliers.data, purchases.data, search]);

  const open = rows.find((r) => r.supplier.id === openId) ?? null;

  const openItems = useMemo(() => {
    if (!open) return [];
    const map = new Map<string, { name: string; unit: string; qty: number; value: number }>();
    for (const inv of open.invoices) {
      for (const line of inv.purchase_items ?? []) {
        const name =
          (lang === "ar" ? line.inventory_items?.name_ar : null) ??
          line.inventory_items?.name ??
          "—";
        const key = `${name}|${line.inventory_items?.unit ?? ""}`;
        const prev = map.get(key) ?? {
          name,
          unit: line.inventory_items?.unit ?? "",
          qty: 0,
          value: 0,
        };
        prev.qty += Number(line.quantity);
        prev.value += Number(line.line_total);
        map.set(key, prev);
      }
    }
    return [...map.values()].sort((a, b) => b.value - a.value);
  }, [open, lang]);

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const totals = rows.reduce(
    (acc, r) => ({
      purchased: acc.purchased + r.purchased,
      paid: acc.paid + r.paid,
      due: acc.due + r.due,
    }),
    { purchased: 0, paid: 0, due: 0 },
  );

  return (
    <div>
      <PageHeader title={t("sup.title")} description={t("sup.subtitle")} />

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        {[
          { label: t("sup.purchased"), value: totals.purchased },
          { label: t("sup.paid"), value: totals.paid },
          { label: t("sup.due"), value: totals.due },
        ].map((card) => (
          <div
            key={card.label}
            className="animate-fade-in rounded-xl border border-border/60 bg-card p-4 transition-transform hover:-translate-y-0.5"
          >
            <p className="text-xs text-muted-foreground">{card.label}</p>
            <p className="mt-1 font-display text-xl font-bold tabular-nums">
              {formatMoney(card.value, currency, lang)}
            </p>
          </div>
        ))}
      </div>

      <Input
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder={t("sup.searchPh")}
        className="mb-4 max-w-sm"
      />

      <DataTable
        rows={rows}
        rowKey={(r) => r.supplier.id}
        onRowClick={(r) => {
          setInvoicePage(0);
          setOpenId(r.supplier.id);
        }}
        emptyMessage={t("sup.empty")}
        pageSize={25}
        columns={[
          {
            id: "name",
            header: t("purch.supplier"),
            sortValue: (r) => r.supplier.name,
            cellClassName: "font-medium",
            cell: (r) => (
              <span className="flex items-center gap-2">
                {r.supplier.name}
                {!r.supplier.is_active && <StatusBadge status={false} />}
              </span>
            ),
          },
          {
            id: "invoices",
            header: t("sup.invoices"),
            align: "center",
            sortValue: (r) => r.invoices.length,
            cellClassName: "tabular-nums",
            cell: (r) => r.invoices.length,
          },
          {
            id: "purchased",
            header: t("sup.purchased"),
            align: "end",
            sortValue: (r) => r.purchased,
            cellClassName: "tabular-nums",
            cell: (r) => formatMoney(r.purchased, currency, lang),
          },
          {
            id: "returned",
            header: t("sup.returned"),
            align: "end",
            sortValue: (r) => r.returned,
            cellClassName: "tabular-nums text-muted-foreground",
            cell: (r) => formatMoney(r.returned, currency, lang),
          },
          {
            id: "paid",
            header: t("sup.paid"),
            align: "end",
            sortValue: (r) => r.paid,
            cellClassName: "tabular-nums text-emerald-600 dark:text-emerald-400",
            cell: (r) => formatMoney(r.paid, currency, lang),
          },
          {
            id: "due",
            header: t("sup.due"),
            align: "end",
            sortValue: (r) => r.due,
            cellClassName: "tabular-nums font-semibold",
            cell: (r) =>
              r.due > 0 ? (
                <span className="text-destructive">{formatMoney(r.due, currency, lang)}</span>
              ) : (
                <StatusBadge status="settled" label={t("sup.settled")} />
              ),
          },
          {
            id: "last",
            header: t("sup.lastPurchase"),
            align: "end",
            sortValue: (r) => r.lastDate,
            cellClassName: "text-muted-foreground",
            cell: (r) => (r.lastDate ? formatDate(r.lastDate, lang) : "—"),
          },
        ]}
      />

      <Dialog open={!!open} onOpenChange={(v) => !v && setOpenId(null)}>
        <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {t("sup.details")} — {open?.supplier.name}
            </DialogTitle>
          </DialogHeader>
          {open && (
            <div className="space-y-5">
              <div className="grid gap-3 sm:grid-cols-4">
                {[
                  { label: t("sup.purchased"), value: open.purchased },
                  { label: t("sup.returned"), value: open.returned },
                  { label: t("sup.paid"), value: open.paid },
                  { label: t("sup.due"), value: open.due },
                ].map((c) => (
                  <div key={c.label} className="rounded-lg border border-border/60 p-3">
                    <p className="text-xs text-muted-foreground">{c.label}</p>
                    <p className="mt-1 font-semibold tabular-nums">
                      {formatMoney(c.value, currency, lang)}
                    </p>
                  </div>
                ))}
              </div>

              <div>
                <p className="mb-2 text-sm font-semibold">{t("sup.itemsBought")}</p>
                <div className="overflow-x-auto rounded-lg border border-border/60">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-start">{t("common.name")}</TableHead>
                        <TableHead className="text-end">{t("sup.qty")}</TableHead>
                        <TableHead className="text-end">{t("sup.value")}</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {openItems.map((it) => (
                        <TableRow key={`${it.name}-${it.unit}`}>
                          <TableCell className="text-start">{it.name}</TableCell>
                          <TableCell className="text-end tabular-nums">
                            {it.qty} {it.unit}
                          </TableCell>
                          <TableCell className="text-end tabular-nums">
                            {formatMoney(it.value, currency, lang)}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              </div>

              <div>
                <p className="mb-2 text-sm font-semibold">{t("purch.invoices")}</p>
                <div className="overflow-x-auto rounded-lg border border-border/60">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-start">{t("ret.invoice")}</TableHead>
                        <TableHead className="text-end">{t("ret.date")}</TableHead>
                        <TableHead className="text-end">{t("ret.total")}</TableHead>
                        <TableHead className="text-end">{t("sup.paid")}</TableHead>
                        <TableHead className="text-end">{t("sup.due")}</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {open.invoices
                        .slice(invoicePage * invoicePageSize, (invoicePage + 1) * invoicePageSize)
                        .map((inv) => {
                        const due = Math.max(
                          0,
                          Number(inv.total) - Number(inv.returned_amount) - Number(inv.paid_amount),
                        );
                        return (
                          <TableRow key={inv.id}>
                            <TableCell className="text-start">
                              {inv.invoice_number ?? inv.id.slice(0, 8)}
                            </TableCell>
                            <TableCell className="text-end">
                              {formatDate(inv.purchase_date, lang)}
                            </TableCell>
                            <TableCell className="text-end tabular-nums">
                              {formatMoney(inv.total, currency, lang)}
                            </TableCell>
                            <TableCell className="text-end tabular-nums">
                              {formatMoney(inv.paid_amount, currency, lang)}
                            </TableCell>
                            <TableCell className="text-end tabular-nums font-medium">
                              {formatMoney(due, currency, lang)}
                            </TableCell>
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                  <Pagination
                    page={invoicePage}
                    pageSize={invoicePageSize}
                    total={open.invoices.length}
                    onPage={setInvoicePage}
                  />
                </div>
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
