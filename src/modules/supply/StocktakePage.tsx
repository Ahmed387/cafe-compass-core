import { UnifiedSearchFilter } from "@/modules/shell/UnifiedSearchFilter";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { ClipboardCheck } from "lucide-react";
import { toast } from "sonner";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Button } from "@/components/ui/button";
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
import { formatDateTime, formatMoney, friendlyError } from "@/lib/format";
import { StocktakeSettlementDialog, type Settlement } from "./StocktakeSettlementDialog";

type Scope = "bar" | "main" | "both";
const SCOPES: { key: Scope; label: string }[] = [
  { key: "bar", label: "البار فقط" },
  { key: "main", label: "المخزن الرئيسي فقط" },
  { key: "both", label: "الاثنين معًا" },
];
const LOC = { bar: "البار", main: "الرئيسي" } as Record<string, string>;
const n = (v: unknown) => Number(v ?? 0);
const fmt = (v: number) => Number(v.toFixed(3)).toString();

export function StocktakePage() {
  const { can, currentBranchId } = useAuth();
  const qc = useQueryClient();
  const [scope, setScope] = useState<Scope>("bar");
  const [counts, setCounts] = useState<Record<string, string>>({});
  const [q, setQ] = useState("");
  const [settleOpen, setSettleOpen] = useState(false);

  const preview = useQuery({
    queryKey: ["stocktake-preview", currentBranchId, scope],
    enabled: !!currentBranchId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("stocktake_preview", {
        _branch_id: currentBranchId!,
        _scope: scope,
      });
      if (error) throw error;
      return data ?? [];
    },
  });

  const history = useQuery({
    queryKey: ["stocktakes", currentBranchId],
    enabled: !!currentBranchId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("stocktakes")
        .select("id,scope,shortage_cost,hr_waste_credit,created_at,notes")
        .eq("branch_id", currentBranchId!)
        .order("created_at", { ascending: false })
        .limit(20);
      if (error) throw error;
      return data;
    },
  });

  const key = (id: string, loc: string) => `${id}:${loc}`;
  const rows = useMemo(
    () =>
      (preview.data ?? [])
        .filter((r) => r.name.toLowerCase().includes(q.toLowerCase()))
        .map((r) => {
          const raw = counts[key(r.item_id, r.location)];
          const counted = raw === undefined || raw === "" ? null : Number(raw);
          const variance = counted === null ? null : counted - n(r.expected);
          const net =
            variance === null ? null : variance < 0 ? Math.min(variance + n(r.allowance), 0) : variance;
          return { ...r, counted, variance, net };
        }),
    [preview.data, counts, q],
  );

  const counted = rows.filter((r) => r.counted !== null);
  const shortage = counted.reduce((s, r) => s + (r.net! < 0 ? -r.net! * n(r.unit_cost) : 0), 0);

  const submit = useMutation({
    mutationFn: async (s: Settlement) => {
      const payload = Object.entries(counts)
        .filter(([, v]) => v !== "")
        .map(([k, v]) => {
          const [item_id, location] = k.split(":");
          return { item_id, location, counted: Number(v) };
        });
      const { error } = await supabase.rpc("submit_stocktake_settled", {
        _branch_id: currentBranchId!,
        _scope: scope,
        _counts: payload,
        _settlement: s.mode,
        ...(s.staffId ? { _staff_id: s.staffId } : {}),
        ...(s.shiftId ? { _shift_id: s.shiftId } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("تم اعتماد الجرد وتحديث المخزون");
      setCounts({});
      setSettleOpen(false);
      qc.invalidateQueries({ queryKey: ["stocktake-preview"] });
      qc.invalidateQueries({ queryKey: ["stocktakes"] });
      qc.invalidateQueries({ queryKey: ["warehouse-stock"] });
      qc.invalidateQueries({ queryKey: ["bar-low-stock"] });
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  if (!can("inventory.view")) return <NoPermission message="لا تملك صلاحية عرض المخزون" />;
  const canApprove = can("inventory.adjust");

  return (
    <div dir="rtl" className="space-y-6">
      <PageHeader
        title="الجرد الذكي"
        description="المتوقع = رصيد آخر جرد + التحويلات الواردة − الصادرة − استهلاك الكاشير + المشتريات. يُسمح بهدر 5% من الاستهلاك، وجزاءات الهدر المسجلة على الموظفين تُخصم من العجز."
      />

      <div className="flex flex-wrap items-center gap-2">
        {SCOPES.map((s) => (
          <Button
            key={s.key}
            variant={scope === s.key ? "default" : "outline"}
            onClick={() => {
              setScope(s.key);
              setCounts({});
            }}
          >
            {s.label}
          </Button>
        ))}
        <UnifiedSearchFilter search={q} onSearch={setQ} placeholder="بحث عن صنف…" className="mb-0 min-w-64 flex-1" />
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        <div className="rounded-lg border p-4">
          <div className="text-sm text-muted-foreground">أصناف تم عدها</div>
          <div className="text-2xl font-semibold">{counted.length}</div>
        </div>
        <div className="rounded-lg border p-4">
          <div className="text-sm text-muted-foreground">أصناف بها عجز صافٍ</div>
          <div className="text-2xl font-semibold text-destructive">
            {counted.filter((r) => r.net! < 0).length}
          </div>
        </div>
        <div className="rounded-lg border border-destructive/40 bg-destructive/10 p-4">
          <div className="text-sm text-muted-foreground">قيمة العجز (قبل خصم الجزاءات)</div>
          <div className="text-2xl font-semibold text-destructive">{formatMoney(shortage)}</div>
        </div>
      </div>

      <div className="rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>الصنف</TableHead>
              <TableHead>المكان</TableHead>
              <TableHead>البداية</TableHead>
              <TableHead>وارد</TableHead>
              <TableHead>استهلاك</TableHead>
              <TableHead>مشتريات</TableHead>
              <TableHead>المتوقع</TableHead>
              <TableHead title="نسبة الهالك المتوقعة لكل خامة من صفحة المخزون">السماح (هالك الخامة)</TableHead>
              <TableHead>المعدود</TableHead>
              <TableHead>الفرق الصافي</TableHead>
              <TableHead>التكلفة</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => {
              const red = r.net !== null && r.net < 0;
              return (
                <TableRow key={key(r.item_id, r.location)} className={red ? "bg-destructive/10" : ""}>
                  <TableCell className="font-medium">{r.name}</TableCell>
                  <TableCell>{LOC[r.location]}</TableCell>
                  <TableCell>{fmt(n(r.start_qty))}</TableCell>
                  <TableCell>{fmt(n(r.transfers_in) - n(r.transfers_out))}</TableCell>
                  <TableCell>{fmt(n(r.consumption))}</TableCell>
                  <TableCell>{fmt(n(r.purchases))}</TableCell>
                  <TableCell className="font-semibold">
                    {fmt(n(r.expected))} {r.unit}
                  </TableCell>
                  <TableCell>{fmt(n(r.allowance))}</TableCell>
                  <TableCell>
                    <Input
                      type="number"
                      min={0}
                      className="h-8 w-24"
                      value={counts[key(r.item_id, r.location)] ?? ""}
                      onChange={(e) =>
                        setCounts((c) => ({ ...c, [key(r.item_id, r.location)]: e.target.value }))
                      }
                    />
                  </TableCell>
                  <TableCell className={red ? "font-semibold text-destructive" : ""}>
                    {r.net === null ? "—" : `${fmt(r.net)} ${r.unit}`}
                  </TableCell>
                  <TableCell className={red ? "font-semibold text-destructive" : ""}>
                    {r.net === null ? "—" : formatMoney(r.net * n(r.unit_cost))}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>

      {canApprove && (
        <Button
          disabled={counted.length === 0 || submit.isPending}
          onClick={() => {
            if (shortage > 0) setSettleOpen(true);
            else if (window.confirm("سيتم ضبط المخزون على الكميات المعدودة. متابعة؟"))
              submit.mutate({ mode: "venue" });
          }}
        >
          <ClipboardCheck className="ml-2 h-4 w-4" /> اعتماد الجرد ({counted.length})
        </Button>
      )}
      {currentBranchId && (
        <StocktakeSettlementDialog
          open={settleOpen}
          onOpenChange={setSettleOpen}
          branchId={currentBranchId}
          shortage={shortage}
          pending={submit.isPending}
          onConfirm={(s) => submit.mutate(s)}
        />
      )}

      <div className="space-y-2">
        <h2 className="text-lg font-semibold">سجل الجرد</h2>
        {(history.data ?? []).length === 0 && (
          <p className="text-sm text-muted-foreground">لا يوجد جرد معتمد بعد.</p>
        )}
        {(history.data ?? []).map((h) => (
          <div key={h.id} className="flex flex-wrap gap-4 rounded-lg border p-3 text-sm">
            <span>{formatDateTime(h.created_at)}</span>
            <span>{SCOPES.find((s) => s.key === h.scope)?.label}</span>
            <span>جزاءات مخصومة: {formatMoney(n(h.hr_waste_credit))}</span>
            <span className={n(h.shortage_cost) > 0 ? "font-semibold text-destructive" : ""}>
              العجز الصافي: {formatMoney(n(h.shortage_cost))}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
