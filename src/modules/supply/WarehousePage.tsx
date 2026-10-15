import { InfoTip } from "@/components/shared/InfoTip";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { AlertTriangle, ArrowLeftRight, Check, X } from "lucide-react";
import { toast } from "sonner";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
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
import { KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import { SmartFilterBar } from "@/modules/shell/SmartFilterBar";

type StockRow = {
  item_id: string;
  name: string;
  unit: string;
  cost: number;
  barMin: number;
  total: number;
  bar: number;
  main: number;
};

type Transfer = {
  id: string;
  status: "pending" | "approved" | "rejected";
  notes: string | null;
  created_at: string;
  reject_reason: string | null;
  stock_transfer_items: { item_id: string; quantity: number }[];
};

export function WarehousePage() {
  const { can, currentBranchId } = useAuth();
  const qc = useQueryClient();
  const canApprove = can("inventory.adjust");
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [q, setQ] = useState("");
  const [onlyLow, setOnlyLow] = useState("all");

  const stock = useQuery({
    queryKey: ["warehouse-stock", currentBranchId],
    enabled: !!currentBranchId,
    queryFn: async (): Promise<StockRow[]> => {
      const [items, bs] = await Promise.all([
        supabase
          .from("inventory_items")
          .select("id,name,name_ar,unit,cost_per_unit,bar_min_qty")
          .eq("is_active", true)
          .order("name"),
        supabase
          .from("branch_stock")
          .select("item_id,quantity,bar_quantity")
          .eq("branch_id", currentBranchId!),
      ]);
      if (items.error) throw items.error;
      if (bs.error) throw bs.error;
      const map = new Map(bs.data.map((r) => [r.item_id, r]));
      return items.data.map((i) => {
        const s = map.get(i.id);
        const total = Number(s?.quantity ?? 0);
        const bar = Number(s?.bar_quantity ?? 0);
        return {
          item_id: i.id,
          name: i.name_ar || i.name,
          unit: i.unit,
          cost: Number(i.cost_per_unit ?? 0),
          barMin: Number(i.bar_min_qty ?? 0),
          total,
          bar,
          main: total - bar,
        };
      });
    },
  });

  const transfers = useQuery({
    queryKey: ["stock-transfers", currentBranchId],
    enabled: !!currentBranchId,
    queryFn: async (): Promise<Transfer[]> => {
      const { data, error } = await supabase
        .from("stock_transfers")
        .select("id,status,notes,created_at,reject_reason,stock_transfer_items(item_id,quantity)")
        .eq("branch_id", currentBranchId!)
        .order("created_at", { ascending: false })
        .limit(50);
      if (error) throw error;
      return data as Transfer[];
    },
  });

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["warehouse-stock"] });
    qc.invalidateQueries({ queryKey: ["stock-transfers"] });
  };

  const request = useMutation({
    mutationFn: async (items: { item_id: string; quantity: number }[]) => {
      const { error } = await supabase.rpc("request_stock_transfer", {
        _branch_id: currentBranchId!,
        _items: items,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("تم إرسال طلب التحويل للمدير");
      setDraft({});
      refresh();
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  // Suggested refill: enough for 2 days of the last week's average use (never below
  // the bar's reorder level), minus what the bar holds, capped at the main store.
  const suggest = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc(
        "bar_refill_suggestions" as never,
        {
          _branch_id: currentBranchId!,
          _days: 2,
        } as never,
      );
      if (error) throw error;
      return (data ?? []) as unknown as { item_id: string; suggested: number }[];
    },
    onSuccess: (rows) => {
      const next: Record<string, string> = {};
      for (const r of rows)
        if (Number(r.suggested) > 0) next[r.item_id] = String(Number(r.suggested));
      setDraft(next);
      toast.success(
        Object.keys(next).length
          ? `اتملت كميات ${Object.keys(next).length} صنف — راجعها وحوّل`
          : "مخزن الكافيه مكفّي، مفيش حاجة محتاجة تتحول",
      );
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  // Managers move stock in one step: the request is created and approved together.
  const transferNow = useMutation({
    mutationFn: async (items: { item_id: string; quantity: number }[]) => {
      const { data: id, error } = await supabase.rpc("request_stock_transfer", {
        _branch_id: currentBranchId!,
        _items: items,
      });
      if (error) throw error;
      const { error: e2 } = await supabase.rpc("decide_stock_transfer", {
        _id: id as unknown as string,
        _approve: true,
      });
      if (e2) throw e2;
    },
    onSuccess: () => {
      toast.success("اتحوّلت الكميات لمخزن الكافيه");
      setDraft({});
      refresh();
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  const decide = useMutation({
    mutationFn: async (v: { id: string; approve: boolean }) => {
      const reason = v.approve ? null : (window.prompt("سبب الرفض؟") ?? "");
      const { error } = await supabase.rpc("decide_stock_transfer", {
        _id: v.id,
        _approve: v.approve,
        ...(reason ? { _reason: reason } : {}),
      });
      if (error) throw error;
    },
    onSuccess: (_d, v) => {
      toast.success(v.approve ? "تم التحويل إلى البار" : "تم رفض الطلب");
      refresh();
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  const setMin = useMutation({
    mutationFn: async (v: { id: string; qty: number }) => {
      const { error } = await supabase.rpc("set_bar_min_qty", { _item_id: v.id, _qty: v.qty });
      if (error) throw error;
    },
    onSuccess: () => refresh(),
    onError: (e) => toast.error(friendlyError(e)),
  });

  const rows = useMemo(
    () =>
      (stock.data ?? []).filter(
        (r) =>
          r.name.toLowerCase().includes(q.trim().toLowerCase()) &&
          (onlyLow === "all" || (r.barMin > 0 && r.bar <= r.barMin)),
      ),
    [stock.data, q, onlyLow],
  );
  const low = (stock.data ?? []).filter((r) => r.barMin > 0 && r.bar <= r.barMin);
  const nameOf = (id: string) => stock.data?.find((r) => r.item_id === id)?.name ?? "—";

  if (!can("inventory.view")) return <NoPermission message="لا تملك صلاحية عرض المخزون" />;

  const draftItems = Object.entries(draft)
    .map(([item_id, v]) => ({ item_id, quantity: Number(v) }))
    .filter((x) => x.quantity > 0);

  return (
    <div dir="rtl" className="space-y-6">
      <PageHeader
        title="المخزن الكبير ومخزن الكافيه"
        description="البضاعة بتتخزن في المخزن الكبير، والبيع بيخصم من مخزن الكافيه (البار). حوّل للكافيه كل يوم بزرار «اقترح الكميات»."
      />
      <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
        <span>الفرق بين المخزن والبار؟</span>
        <InfoTip title="المخزن الرئيسي والبار">
          المخزن الرئيسي هو المكان اللي البضاعة بتتشال فيه بعد الشراء. البار هو الكمية اللي قدامك
          وبتشتغل منها، وأي بيعة في الكاشير بتخصم من البار بس. الإجمالي = الرئيسي + البار.
        </InfoTip>
      </div>

      {low.length > 0 && (
        <div className="rounded-lg border border-destructive/40 bg-destructive/10 p-4">
          <div className="mb-2 flex items-center gap-2 font-semibold text-destructive">
            <AlertTriangle className="h-4 w-4" /> اطلب من المخزن الرئيسي ({low.length})
          </div>
          <div className="flex flex-wrap gap-2">
            {low.map((r) => (
              <Button
                key={r.item_id}
                size="sm"
                variant="outline"
                onClick={() =>
                  setDraft((d) => ({
                    ...d,
                    [r.item_id]: String(Math.max(r.barMin * 2 - r.bar, r.barMin)),
                  }))
                }
              >
                {r.name}: {r.bar} {r.unit}
              </Button>
            ))}
          </div>
        </div>
      )}

      <KpiGrid cols={3}>
        <KpiCard
          label="إجمالي الأصناف"
          value={rows.length}
          tone="brand"
          formula="عدد الأصناف المطابقة للبحث والفلاتر الحالية."
        />
        <KpiCard
          label="أصناف وصلت لحد إعادة الطلب"
          value={rows.filter((r) => r.barMin > 0 && r.bar <= r.barMin).length}
          tone="bad"
          formula="رصيد البار أقل من أو يساوي حد إعادة الطلب."
        />
        <KpiCard
          label="قيمة المخزون الإجمالية"
          value={formatMoney(rows.reduce((t, r) => t + r.total * r.cost, 0))}
          hint={`البار: ${formatMoney(rows.reduce((t, r) => t + r.bar * r.cost, 0))}`}
          formula="مجموع إجمالي رصيد الفرع × تكلفة الوحدة لكل صنف."
        />
      </KpiGrid>
      <div className="flex flex-wrap items-start gap-2">
        <div className="min-w-64 flex-1">
          <SmartFilterBar
            search={q}
            onSearch={setQ}
            placeholder="بحث عن صنف…"
            filters={[
              {
                key: "low",
                label: "الحالة",
                value: onlyLow,
                onChange: setOnlyLow,
                options: [
                  { value: "all", label: "كل الأصناف" },
                  { value: "low", label: "الناقص في البار فقط" },
                ],
              },
            ]}
          />
        </div>
        <Button variant="outline" disabled={suggest.isPending} onClick={() => suggest.mutate()}>
          اقترح الكميات (تكفي يومين)
        </Button>
        {canApprove ? (
          <Button
            disabled={draftItems.length === 0 || transferNow.isPending}
            onClick={() => transferNow.mutate(draftItems)}
          >
            <ArrowLeftRight className="ml-2 h-4 w-4" />
            حوّل لمخزن الكافيه دلوقتي ({draftItems.length})
          </Button>
        ) : (
          <Button
            disabled={draftItems.length === 0 || request.isPending}
            onClick={() => request.mutate(draftItems)}
          >
            <ArrowLeftRight className="ml-2 h-4 w-4" />
            اطلب تحويل لمخزن الكافيه ({draftItems.length})
          </Button>
        )}
        <InfoTip title="التحويل">
          اكتب الكمية اللي عايز تنقلها من المخزن الرئيسي للبار. الطلب بيروح للمدير يوافق عليه، وبعد
          الموافقة الكمية بتتخصم من الرئيسي وتتزود في البار. الإجمالي ما بيتغيرش.
        </InfoTip>
      </div>

      <div className="rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>الصنف</TableHead>
              <TableHead>
                <span className="inline-flex items-center gap-1">
                  المخزن الكبير<InfoTip>البضاعة المتشالة في المخزن، لسه مانزلتش الكافيه.</InfoTip>
                </span>
              </TableHead>
              <TableHead>
                <span className="inline-flex items-center gap-1">
                  مخزن الكافيه
                  <InfoTip>
                    الكمية اللي في الكافيه وبيتخصم منها البيع على طول. لو بالسالب يبقى اتباع أكتر من
                    اللي اتحوّل.
                  </InfoTip>
                </span>
              </TableHead>
              <TableHead>
                <span className="inline-flex items-center gap-1">
                  حد طلب البار
                  <InfoTip title="حد طلب البار">
                    رقم تحذيري بتحدده عشان تقول للسيستم: لو الكمية وصلت للرقم ده، ابدأ نبهني. هو مش
                    كمية بضاعة فعلية، ده خط إنذار أحمر. مثال: لو حطيته 2 كيلو، أول ما البار يوصل 2
                    كيلو هيظهرلك تنبيه تطلب من المخزن.
                  </InfoTip>
                </span>
              </TableHead>
              <TableHead>قيمة البار</TableHead>
              <TableHead>كمية التحويل</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => {
              const isLow = r.barMin > 0 && r.bar <= r.barMin;
              return (
                <TableRow key={r.item_id}>
                  <TableCell className="font-medium">{r.name}</TableCell>
                  <TableCell>
                    {r.main} {r.unit}
                  </TableCell>
                  <TableCell className={isLow ? "font-semibold text-destructive" : ""}>
                    {r.bar} {r.unit}
                  </TableCell>
                  <TableCell>
                    {canApprove ? (
                      <Input
                        type="number"
                        min={0}
                        defaultValue={r.barMin}
                        className="h-8 w-24"
                        onBlur={(e) => {
                          const v = Number(e.target.value);
                          if (v !== r.barMin) setMin.mutate({ id: r.item_id, qty: v });
                        }}
                      />
                    ) : (
                      r.barMin
                    )}
                  </TableCell>
                  <TableCell>{formatMoney(r.bar * r.cost)}</TableCell>
                  <TableCell>
                    <Input
                      type="number"
                      min={0}
                      className="h-8 w-24"
                      value={draft[r.item_id] ?? ""}
                      onChange={(e) => setDraft((d) => ({ ...d, [r.item_id]: e.target.value }))}
                    />
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>

      <div className="space-y-3">
        <h2 className="text-lg font-semibold">طلبات التحويل</h2>
        {(transfers.data ?? []).length === 0 && (
          <p className="text-sm text-muted-foreground">لا توجد طلبات بعد.</p>
        )}
        {(transfers.data ?? []).map((t) => (
          <div key={t.id} className="rounded-lg border p-3">
            <div className="flex flex-wrap items-center gap-2">
              <Badge
                variant={
                  t.status === "approved"
                    ? "default"
                    : t.status === "rejected"
                      ? "destructive"
                      : "secondary"
                }
              >
                {t.status === "approved"
                  ? "تمت الموافقة"
                  : t.status === "rejected"
                    ? "مرفوض"
                    : "قيد الانتظار"}
              </Badge>
              <span className="text-sm text-muted-foreground">{formatDateTime(t.created_at)}</span>
              <div className="flex-1" />
              {t.status === "pending" && canApprove && (
                <>
                  <Button
                    size="sm"
                    disabled={decide.isPending}
                    onClick={() => decide.mutate({ id: t.id, approve: true })}
                  >
                    <Check className="ml-1 h-4 w-4" /> موافقة
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={decide.isPending}
                    onClick={() => decide.mutate({ id: t.id, approve: false })}
                  >
                    <X className="ml-1 h-4 w-4" /> رفض
                  </Button>
                </>
              )}
            </div>
            <div className="mt-2 text-sm">
              {t.stock_transfer_items.map((i) => `${nameOf(i.item_id)} × ${i.quantity}`).join("، ")}
            </div>
            {t.reject_reason && (
              <div className="mt-1 text-sm text-destructive">السبب: {t.reject_reason}</div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
