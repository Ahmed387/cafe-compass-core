import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { InfoTip } from "@/components/shared/InfoTip";
import { WasteCell } from "@/modules/supply/WasteCell";
import {
  InventoryItemDialog,
  deriveUnitCost,
  emptyInventoryItem,
  type InventoryItemForm,
} from "@/modules/supply/InventoryItemDialog";
import { WasteLogDialog } from "@/modules/supply/WasteLogDialog";
import { WASTE_BEARERS, type WasteBearer } from "@/modules/supply/WasteBearerPicker";
import { useStaffCandidates } from "@/modules/operations/shift-workflow";
import { useEffect, useMemo, useState } from "react";
import { ArrowLeftRight, Pencil, Plus, Power, Search, Trash2, X } from "lucide-react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
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
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney, friendlyError } from "@/lib/format";
import { UnifiedSearchFilter } from "@/modules/shell/UnifiedSearchFilter";
import { useI18n } from "@/lib/i18n";
import { KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import {
  canEditMovement,
  canVoidMovement,
  movementsForTab,
  stockAfterVoid,
  stockAfterVoidAll,
} from "@/core/inventory/movement-void";

export const Route = createFileRoute("/_authenticated/inventory")({
  head: () => ({
    meta: [
      { title: "Inventory — 20s Coffee" },
      {
        name: "description",
        content: "Track stock per branch and record purchases, waste, adjustments and stocktakes.",
      },
      { property: "og:title", content: "Inventory — 20s Coffee" },
      {
        property: "og:description",
        content: "Stock levels and inventory movements for 20s Coffee.",
      },
    ],
  }),
  validateSearch: (search: Record<string, unknown>) => ({
    tab:
      search["tab"] === "movements" || search["tab"] === "voided"
        ? (search["tab"] as "movements" | "voided")
        : "stock",
  }),
  component: InventoryPage,
});

const UNITS = ["kg", "g", "liter", "ml", "pcs", "box"];
// Waste has its own form (who bears the cost is mandatory).
const MOVE_TYPES = ["purchase", "adjustment", "stocktake"] as const;

type BulkRow = {
  name_ar: string;
  name: string;
  unit: string;
  cost_per_unit: string;
  total_cost: string;
  min_qty: string;
  opening_qty: string;
};

const emptyBulkRow: BulkRow = {
  name_ar: "",
  name: "",
  unit: "kg",
  cost_per_unit: "0",
  total_cost: "",
  min_qty: "0",
  opening_qty: "0",
};

/** Debounced mirror of a text input so large tables do not re-filter on every keystroke. */
function useDebounced(value: string, delay = 150) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(timer);
  }, [value, delay]);
  return debounced;
}

function SearchBar({
  value,
  onChange,
  placeholder,
}: {
  value: string;
  onChange: (next: string) => void;
  placeholder: string;
  clearLabel: string;
}) {
  return (
    <UnifiedSearchFilter
      search={value}
      onSearch={onChange}
      placeholder={placeholder}
      className="mb-0"
    />
  );
}

function InventoryPage() {
  const { t, lang } = useI18n();
  const { me, can, currentBranchId } = useAuth();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";

  const showError = (error: unknown) => toast.error(friendlyError(error, lang));

  const [itemDialog, setItemDialog] = useState(false);
  const [itemForm, setItemForm] = useState<InventoryItemForm>(emptyInventoryItem);
  const [moveDialog, setMoveDialog] = useState(false);
  const [wasteDialog, setWasteDialog] = useState(false);
  const [moveItem, setMoveItem] = useState<string>("");
  const [moveType, setMoveType] = useState<(typeof MOVE_TYPES)[number]>("purchase");
  const [moveQty, setMoveQty] = useState("");
  const [moveCost, setMoveCost] = useState("");
  const [moveTotal, setMoveTotal] = useState("");
  const [moveReason, setMoveReason] = useState("");
  const search = Route.useSearch();
  const [tab, setTab] = useState(search.tab);
  const [wipeDialog, setWipeDialog] = useState(false);
  const [wipeWord, setWipeWord] = useState("");
  const [bulkDialog, setBulkDialog] = useState(false);
  const [bulkRows, setBulkRows] = useState<BulkRow[]>([{ ...emptyBulkRow }]);
  const [itemToDelete, setItemToDelete] = useState<{ id: string; name: string } | null>(null);
  const [deleteUsage, setDeleteUsage] = useState<{
    products: Array<{ id: string; name: string; name_ar: string | null }>;
    modifiers: Array<{ id: string; name: string; name_ar: string | null }>;
  } | null>(null);
  const [stockQuery, setStockQuery] = useState("");
  const [movesQuery, setMovesQuery] = useState("");
  const [moveEdit, setMoveEdit] = useState<{
    id: string;
    item: string;
    type: string;
    created_at: string;
    quantity: string;
    unit_cost: string;
    reason: string;
  } | null>(null);
  const [moveVoid, setMoveVoid] = useState<{
    id: string;
    item: string;
    type: string;
    created_at: string;
    quantity: number;
    stockAfter: number;
    reason: string;
  } | null>(null);

  // Movements ticked for cancelling together (movements tab only).
  const [picked, setPicked] = useState<string[]>([]);
  const [bulkVoidOpen, setBulkVoidOpen] = useState(false);
  const [bulkVoidReason, setBulkVoidReason] = useState("");
  // Hand-typed movements only, further back than the latest 100 (sales push them out).
  const [manualOnly, setManualOnly] = useState(false);
  useEffect(() => setPicked([]), [tab, currentBranchId, manualOnly]);

  const canView = can("inventory.view");
  const canAdjust = can("inventory.adjust");
  const canWaste = can("inventory.waste");
  const canWipe = canAdjust;
  const canChargeStaff = canAdjust || can("payroll.manage");
  const staffList = useStaffCandidates(canView);

  const wipeAll = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc("wipe_all_raw_materials");
      if (error) throw error;
      return data as { items_deleted: number };
    },
    onSuccess: () => {
      setWipeDialog(false);
      setWipeWord("");
      toast.success(t("inv.wipeDone"));
      for (const key of [
        "inventory-items",
        "branch-stock",
        "stock-movements",
        "product-recipes",
        "modifier-recipes",
        "products",
      ]) {
        queryClient.invalidateQueries({ queryKey: [key] });
      }
    },
    onError: showError,
  });

  const items = useQuery({
    queryKey: ["inventory-items"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("inventory_items")
        .select("id, name, name_ar, sku, unit, cost_per_unit, min_qty, waste_pct, is_active")
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
    enabled: canView,
  });

  const stock = useQuery({
    queryKey: ["branch-stock", currentBranchId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("branch_stock")
        .select("item_id, quantity")
        .eq("branch_id", currentBranchId!);
      if (error) throw error;
      return data ?? [];
    },
    enabled: canView && Boolean(currentBranchId),
  });

  const movements = useQuery({
    queryKey: ["stock-movements", currentBranchId, manualOnly],
    queryFn: async () => {
      let query = supabase
        .from("stock_movements")
        .select(
          "id, item_id, movement_type, quantity, unit_cost, balance_after, reason, reference_type, created_at, waste_bearer, waste_staff_id, voided_at, void_reason, inventory_items(name, name_ar, unit)",
        )
        .eq("branch_id", currentBranchId!)
        .is("voided_at", null);
      if (manualOnly)
        query = query.in("reference_type", ["manual", "opening_balance", "stock_reset"]);
      const { data, error } = await query
        .order("created_at", { ascending: false })
        .limit(manualOnly ? 500 : 100);
      if (error) throw error;
      return data ?? [];
    },
    enabled: canView && Boolean(currentBranchId),
  });

  const voidedMovements = useQuery({
    queryKey: ["stock-movements", "voided", currentBranchId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("stock_movements")
        .select(
          "id, item_id, movement_type, quantity, unit_cost, balance_after, reason, reference_type, created_at, waste_bearer, waste_staff_id, voided_at, void_reason, inventory_items(name, name_ar, unit)",
        )
        .eq("branch_id", currentBranchId!)
        .not("voided_at", "is", null)
        .order("voided_at", { ascending: false })
        .limit(200);
      if (error) throw error;
      return data ?? [];
    },
    enabled: canView && Boolean(currentBranchId),
  });

  const stockMap = new Map((stock.data ?? []).map((row) => [row.item_id, Number(row.quantity)]));
  const itemName = (row: { name: string; name_ar: string | null } | null) =>
    (lang === "ar" ? row?.name_ar || row?.name : row?.name) ?? "—";

  const stockTerm = useDebounced(stockQuery).trim().toLowerCase();
  const movesTerm = useDebounced(movesQuery).trim().toLowerCase();

  const hit = (term: string, ...values: Array<string | null | undefined>) =>
    !term || values.some((value) => (value ?? "").toLowerCase().includes(term));

  const filteredItems = useMemo(
    () =>
      (items.data ?? []).filter((row) => hit(stockTerm, row.name, row.name_ar, row.sku, row.unit)),
    [items.data, stockTerm],
  );

  const filteredMovements = useMemo(
    () =>
      movementsForTab((tab === "voided" ? voidedMovements.data : movements.data) ?? [], tab).filter(
        (row) =>
          hit(
            movesTerm,
            row.inventory_items?.name,
            row.inventory_items?.name_ar,
            row.reason,
            row.void_reason,
            row.movement_type,
            t(`inv.type.${row.movement_type}`),
          ),
      ),
    [movements.data, voidedMovements.data, tab, movesTerm, lang],
  );

  const canPick = canAdjust && tab === "movements";
  const pickable = canPick ? filteredMovements.filter(canVoidMovement) : [];
  const allPicked = pickable.length > 0 && pickable.every((row) => picked.includes(row.id));
  const pickedRows = (movements.data ?? []).filter((row) => picked.includes(row.id));
  const pickedByItem = stockAfterVoidAll(stockMap, pickedRows);
  const pickedNames = new Map(
    pickedRows.map((row) => [row.item_id, itemName(row.inventory_items)]),
  );
  const togglePick = (id: string, on: boolean) =>
    setPicked((cur) => (on ? [...new Set([...cur, id])] : cur.filter((x) => x !== id)));

  const isLow = (row: { id: string; min_qty: number | null }) =>
    Number(row.min_qty ?? 0) > 0 && (stockMap.get(row.id) ?? 0) <= Number(row.min_qty ?? 0);
  const [lowOnly, setLowOnly] = useState(false);
  const shownItems = lowOnly ? filteredItems.filter(isLow) : filteredItems;
  const lowItems = filteredItems.filter(isLow);
  const stockValue = shownItems.reduce(
    (t, r) => t + (stockMap.get(r.id) ?? 0) * Number(r.cost_per_unit ?? 0),
    0,
  );

  const linkedCount = (deleteUsage?.products.length ?? 0) + (deleteUsage?.modifiers.length ?? 0);

  const refreshStock = async () => {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["inventory-items"] }),
      queryClient.invalidateQueries({ queryKey: ["branch-stock"] }),
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] }),
    ]);
  };

  const bulkSave = useMutation({
    mutationFn: async () => {
      const rows = bulkRows.filter((row) => row.name_ar.trim() || row.name.trim());
      if (rows.length === 0) throw new Error(t("inv.nameRequired"));
      const { error } = await supabase.rpc("bulk_create_inventory_items", {
        _items: rows.map((row) => ({
          name: row.name.trim() || row.name_ar.trim(),
          name_ar: row.name_ar.trim() || null,
          unit: row.unit,
          cost_per_unit: Number(row.cost_per_unit || 0),
          min_qty: Number(row.min_qty || 0),
          opening_qty: Number(row.opening_qty || 0),
        })),
        ...(currentBranchId ? { _branch_id: currentBranchId } : {}),
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success(t("inv.bulkSaved"));
      setBulkDialog(false);
      setBulkRows([{ ...emptyBulkRow }]);
      await refreshStock();
    },
    onError: showError,
  });

  const deleteItem = useMutation({
    mutationFn: async ({ id, unlink }: { id: string; unlink: boolean }) => {
      const { error } = await supabase.rpc("delete_inventory_item", {
        _item_id: id,
        _unlink_recipes: unlink,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success(t("inv.itemDeleted"));
      setItemToDelete(null);
      setDeleteUsage(null);
      await refreshStock();
      await queryClient.invalidateQueries({ queryKey: ["recipes"] });
      await queryClient.invalidateQueries({ queryKey: ["modifier-recipes"] });
    },
    onError: (error) => {
      setItemToDelete(null);
      setDeleteUsage(null);
      showError(error);
    },
  });

  // Keeps recipes intact while taking the raw material out of circulation.
  const disableItem = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from("inventory_items")
        .update({ is_active: false })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success(t("inv.itemDisabled"));
      setItemToDelete(null);
      setDeleteUsage(null);
      await refreshStock();
    },
    onError: showError,
  });

  // Reads the dependency map first so the dialog can offer cascade or disable.
  const openDelete = async (target: { id: string; name: string }) => {
    setItemToDelete(target);
    setDeleteUsage(null);
    const { data, error } = await supabase.rpc("inventory_item_usage", { _item_id: target.id });
    if (error) {
      showError(error);
      return;
    }
    const usage = data as {
      products: Array<{ id: string; name: string; name_ar: string | null }>;
      modifiers: Array<{ id: string; name: string; name_ar: string | null }>;
    };
    setDeleteUsage({ products: usage?.products ?? [], modifiers: usage?.modifiers ?? [] });
  };

  const editMovement = useMutation({
    mutationFn: async () => {
      if (!moveEdit) return;
      if (!moveEdit.reason.trim()) throw new Error(t("inv.reasonRequired"));
      const { error } = await supabase.rpc("edit_stock_movement", {
        _movement_id: moveEdit.id,
        _quantity: Number(moveEdit.quantity || 0),
        _unit_cost: Number(moveEdit.unit_cost || 0),
        _reason: moveEdit.reason.trim(),
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success(t("inv.movementUpdated"));
      setMoveEdit(null);
      await refreshStock();
    },
    onError: showError,
  });

  // Cancel a manual movement: the row stays, marked cancelled; the database
  // takes it out of the stock and recalculates the sales cost.
  const voidMovement = useMutation({
    mutationFn: async () => {
      if (!moveVoid) return null;
      if (moveVoid.reason.trim().length < 3) throw new Error(t("inv.reasonRequired"));
      const { data, error } = await supabase.rpc("void_stock_movement", {
        _movement_id: moveVoid.id,
        _reason: moveVoid.reason.trim(),
      });
      if (error) throw error;
      return data as { stock_after: number; negative: boolean } | null;
    },
    onSuccess: async (data) => {
      if (data?.negative) toast.warning(t("inv.movementVoidedNegative"));
      else toast.success(t("inv.movementVoided"));
      setMoveVoid(null);
      await refreshStock();
    },
    onError: showError,
  });

  const voidPicked = useMutation({
    mutationFn: async () => {
      if (bulkVoidReason.trim().length < 3) throw new Error(t("inv.reasonRequired"));
      const { data, error } = await supabase.rpc("void_stock_movements", {
        _movement_ids: picked,
        _reason: bulkVoidReason.trim(),
      });
      if (error) throw error;
      return data as { cancelled: number; negative: boolean } | null;
    },
    onSuccess: async (data) => {
      const n = data?.cancelled ?? picked.length;
      if (data?.negative) toast.warning(t("inv.movementsVoidedNegative").replace("{n}", String(n)));
      else toast.success(t("inv.movementsVoided").replace("{n}", String(n)));
      setBulkVoidOpen(false);
      setBulkVoidReason("");
      setPicked([]);
      await refreshStock();
    },
    onError: showError,
  });

  const toggleItem = useMutation({
    mutationFn: async (row: { id: string; is_active: boolean }) => {
      const { error } = await supabase
        .from("inventory_items")
        .update({ is_active: !row.is_active })
        .eq("id", row.id);
      if (error) throw error;
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["inventory-items"] });
    },
    onError: showError,
  });

  const submitMovement = useMutation({
    mutationFn: async () => {
      if (!currentBranchId) throw new Error(t("inv.branchRequired"));
      if (!moveItem) throw new Error(t("inv.itemRequired"));
      const qty = Number(moveQty);
      if (!qty && moveType !== "stocktake") throw new Error(t("inv.qtyRequired"));
      const { error } = await supabase.rpc("record_stock_movement", {
        _branch_id: currentBranchId,
        _item_id: moveItem,
        _type: moveType,
        _qty: qty,
        ...(moveCost ? { _unit_cost: Number(moveCost) } : {}),
        ...(moveReason.trim() ? { _reason: moveReason.trim() } : {}),
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success(t("inv.movementSaved"));
      setMoveDialog(false);
      setMoveQty("");
      setMoveCost("");
      setMoveTotal("");
      setMoveReason("");
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["branch-stock"] }),
        queryClient.invalidateQueries({ queryKey: ["stock-movements"] }),
      ]);
    },
    onError: showError,
  });

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const availableTypes = MOVE_TYPES.filter(() => canAdjust);
  const staffNames = new Map((staffList.data ?? []).map((p) => [p.id, p.name]));

  return (
    <div>
      <PageHeader
        title={t("inv.title")}
        description={t("inv.subtitle")}
        action={
          <div className="flex flex-wrap gap-2">
            {canWipe && (
              <Button
                variant="outline"
                className="border-destructive text-destructive hover:bg-destructive/10"
                onClick={() => {
                  setWipeWord("");
                  setWipeDialog(true);
                }}
              >
                <Trash2 className="me-2 h-4 w-4" />
                {t("inv.wipeAll")}
              </Button>
            )}
            {canAdjust && (
              <Button
                variant="outline"
                icon={Plus}
                onClick={() => {
                  setItemForm(emptyInventoryItem);
                  setItemDialog(true);
                }}
              >
                {t("inv.newItem")}
              </Button>
            )}
            {canAdjust && (
              <Button
                variant="outline"
                className="border-primary text-primary hover:bg-primary/10"
                onClick={() => {
                  setBulkRows([{ ...emptyBulkRow }]);
                  setBulkDialog(true);
                }}
              >
                {t("inv.bulkAdd")}
              </Button>
            )}
            {canWaste && (
              <Button
                variant="outline"
                icon={Trash2}
                className="border-destructive/40 text-destructive hover:border-destructive hover:bg-destructive/10 hover:text-destructive"
                onClick={() => setWasteDialog(true)}
              >
                {lang === "ar" ? "تسجيل هالك" : "Log waste"}
              </Button>
            )}
            {canAdjust && (
              <Button
                icon={ArrowLeftRight}
                onClick={() => {
                  setMoveItem(items.data?.[0]?.id ?? "");
                  setMoveType(availableTypes[0] ?? "adjustment");
                  setMoveDialog(true);
                }}
              >
                {t("inv.newMovement")}
              </Button>
            )}
          </div>
        }
      />

      <AlertDialog open={wipeDialog} onOpenChange={setWipeDialog}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("inv.wipeTitle")}</AlertDialogTitle>
            <AlertDialogDescription>{t("inv.wipeDesc")}</AlertDialogDescription>
          </AlertDialogHeader>
          <div className="space-y-1">
            <Label>{t("inv.wipeTypeWord")}</Label>
            <Input
              value={wipeWord}
              onChange={(e) => setWipeWord(e.target.value)}
              placeholder="تأكيد"
              className="text-start"
            />
          </div>
          <AlertDialogFooter>
            <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
            <Button
              variant="destructive"
              disabled={wipeWord.trim() !== "تأكيد" || wipeAll.isPending}
              onClick={() => wipeAll.mutate()}
            >
              {t("inv.wipeConfirm")}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <Tabs value={tab} onValueChange={setTab}>
        <div className="-mx-1 overflow-x-auto px-1 pb-1">
          <TabsList className="w-max">
            <TabsTrigger value="stock">{t("inv.stock")}</TabsTrigger>
            <TabsTrigger value="movements">{t("inv.movements")}</TabsTrigger>
            <TabsTrigger value="voided">
              {t("inv.voidedMovements")}
              {(voidedMovements.data ?? []).length > 0 && (
                <Badge variant="secondary" className="ms-1.5 h-5 px-1.5 text-[10px] tabular-nums">
                  {(voidedMovements.data ?? []).length}
                </Badge>
              )}
            </TabsTrigger>
          </TabsList>
        </div>

        <TabsContent value="stock" className="mt-4 space-y-3">
          <KpiGrid cols={3}>
            <KpiCard
              label={lang === "ar" ? "إجمالي الأصناف" : "Total items"}
              value={shownItems.length}
              tone="brand"
              formula={
                lang === "ar"
                  ? "عدد أصناف المخزون المطابقة للفلاتر."
                  : "Inventory items matching the filters."
              }
              details={
                <div className="space-y-2">
                  {shownItems.map((row) => (
                    <div
                      key={row.id}
                      className="flex justify-between gap-3 rounded-lg border border-border p-3 text-sm"
                    >
                      <span>{lang === "ar" ? (row.name_ar ?? row.name) : row.name}</span>
                      <span className="tabular-nums">
                        {stockMap.get(row.id) ?? 0} {row.unit}
                      </span>
                    </div>
                  ))}
                </div>
              }
            />
            <KpiCard
              label={lang === "ar" ? "أصناف وصلت لحد إعادة الطلب" : "At reorder level"}
              value={lowItems.length}
              tone={lowItems.length ? "bad" : "good"}
              formula={
                lang === "ar"
                  ? "الرصيد الحالي أقل من أو يساوي حد إعادة الطلب."
                  : "Current quantity is at or below reorder level."
              }
              details={
                <div className="space-y-2">
                  {lowItems.map((row) => (
                    <div
                      key={row.id}
                      className="flex justify-between gap-3 rounded-lg border border-border p-3 text-sm"
                    >
                      <span>{lang === "ar" ? (row.name_ar ?? row.name) : row.name}</span>
                      <span className="tabular-nums text-destructive">
                        {stockMap.get(row.id) ?? 0} {row.unit}
                      </span>
                    </div>
                  ))}
                </div>
              }
            />
            <KpiCard
              label={lang === "ar" ? "قيمة المخزون الإجمالية" : "Total stock value"}
              value={formatMoney(stockValue, currency, lang)}
              formula={
                lang === "ar"
                  ? "مجموع الرصيد الحالي × تكلفة الوحدة لكل صنف."
                  : "Sum of current quantity × unit cost per item."
              }
            />
          </KpiGrid>
          <label className="flex min-h-11 w-max cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              className="size-4 accent-primary"
              checked={lowOnly}
              onChange={(e) => setLowOnly(e.target.checked)}
            />
            {lang === "ar" ? "الناقص فقط" : "Low stock only"}
          </label>
          <SearchBar
            value={stockQuery}
            onChange={setStockQuery}
            placeholder={t("inv.searchStock")}
            clearLabel={t("inv.clearSearch")}
          />
          {(items.data ?? []).length > 0 && (
            <p className="font-mono text-xs tabular-nums text-muted-foreground">
              {t("inv.matchCount")
                .replace("{shown}", String(shownItems.length))
                .replace("{total}", String((items.data ?? []).length))}
            </p>
          )}
          {(items.data ?? []).length === 0 ? (
            <EmptyState message={t("inv.emptyItems")} />
          ) : shownItems.length === 0 ? (
            <EmptyState message={t("inv.noMatches")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card shadow-sm">
              <Table className="min-w-[860px] text-xs">
                <TableHeader className="bg-muted/45">
                  <TableRow className="hover:bg-muted/45">
                    <TableHead className="h-9 min-w-52 px-3 text-start font-semibold">
                      {t("inv.item")}
                    </TableHead>
                    <TableHead className="h-9 w-20 whitespace-nowrap px-2 text-center font-semibold">
                      {t("inv.unit")}
                    </TableHead>
                    <TableHead className="h-9 w-32 whitespace-nowrap px-2 text-center font-semibold">
                      {t("inv.onHand")}
                    </TableHead>
                    <TableHead className="h-9 w-24 whitespace-nowrap px-2 text-center font-semibold">
                      {t("inv.minQty")}
                    </TableHead>
                    <TableHead className="h-9 w-32 whitespace-nowrap px-3 text-end font-semibold">
                      {t("inv.unitCost")}
                    </TableHead>
                    <TableHead className="h-9 w-28 whitespace-nowrap px-2 text-center font-semibold">
                      <span className="inline-flex items-center gap-1">
                        {lang === "ar" ? "الهالك" : "Waste"}
                        <InfoTip
                          title={lang === "ar" ? "ليه الهالك لكل خامة؟" : "Why waste per item?"}
                        >
                          {lang === "ar"
                            ? "نسبة الهالك المتوقعة لكل خامة (افتراضيًا 0%). رقم داخلي للمتابعة وسماحية للجرد بس — مش بيزوّد تكلفة الصنف ولا سعر المنيو. الهالك الفعلي بيتسجل من زرار «تسجيل هالك» مع تحديد مين يتحمله."
                            : "Expected waste per ingredient (0% by default). An internal tracking figure and stocktake tolerance only — it never raises the item cost or menu prices. Actual waste is logged with “Log waste”, choosing who bears it."}
                        </InfoTip>
                      </span>
                    </TableHead>
                    <TableHead className="h-9 w-32 whitespace-nowrap px-3 text-end font-semibold">
                      {t("inv.value")}
                    </TableHead>
                    <TableHead className="h-9 w-28 whitespace-nowrap px-2 text-center font-semibold">
                      {t("common.actions")}
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {shownItems.map((row) => {
                    const qty = stockMap.get(row.id) ?? 0;
                    const low = qty <= Number(row.min_qty);
                    return (
                      <TableRow key={row.id} className="h-11 even:bg-muted/20">
                        <TableCell className="min-w-52 px-3 py-1.5 font-medium">
                          <span className="whitespace-nowrap">{itemName(row)}</span>
                          {!row.is_active && (
                            <Badge variant="outline" className="ms-2 h-5 px-1.5 text-[10px]">
                              {t("common.inactive")}
                            </Badge>
                          )}
                        </TableCell>
                        <TableCell className="w-20 px-2 py-1.5 text-center text-muted-foreground">
                          {row.unit}
                        </TableCell>
                        <TableCell className="w-32 px-2 py-1.5 text-center tabular-nums">
                          <span className={low ? "font-semibold text-destructive" : ""}>{qty}</span>
                          {low && (
                            <Badge variant="destructive" className="ms-1.5 h-5 px-1.5 text-[10px]">
                              {t("inv.low")}
                            </Badge>
                          )}
                        </TableCell>
                        <TableCell className="w-24 px-2 py-1.5 text-center tabular-nums text-muted-foreground">
                          {Number(row.min_qty)}
                        </TableCell>
                        <TableCell className="w-32 whitespace-nowrap px-3 py-1.5 text-end tabular-nums">
                          {formatMoney(row.cost_per_unit, currency, lang)}
                        </TableCell>
                        <TableCell className="w-28 px-2 py-1 text-center">
                          <WasteCell
                            itemId={row.id}
                            value={Number(row.waste_pct ?? 0)}
                            editable={canAdjust}
                            lang={lang === "ar" ? "ar" : "en"}
                          />
                        </TableCell>
                        <TableCell className="w-32 whitespace-nowrap px-3 py-1.5 text-end font-semibold tabular-nums">
                          {formatMoney(qty * Number(row.cost_per_unit), currency, lang)}
                        </TableCell>
                        <TableCell className="w-28 px-2 py-1 text-center">
                          {canAdjust && (
                            <div className="flex items-center justify-center gap-0.5">
                              <Button
                                size="icon"
                                variant="ghost"
                                className="size-8"
                                title={t("common.edit")}
                                aria-label={t("common.edit")}
                                onClick={() => {
                                  setItemForm({
                                    id: row.id,
                                    name: row.name,
                                    name_ar: row.name_ar ?? "",
                                    unit: row.unit,
                                    sku: row.sku ?? "",
                                    cost_per_unit: String(row.cost_per_unit),
                                    total_cost: "",
                                    min_qty: String(row.min_qty),
                                    opening_qty: "0",
                                    waste_pct: String(row.waste_pct ?? 0),
                                  });
                                  setItemDialog(true);
                                }}
                              >
                                <Pencil className="size-3.5" />
                              </Button>
                              <Button
                                size="icon"
                                variant="ghost"
                                className="size-8"
                                title={row.is_active ? t("common.disable") : t("common.enable")}
                                aria-label={
                                  row.is_active ? t("common.disable") : t("common.enable")
                                }
                                onClick={() => toggleItem.mutate(row)}
                              >
                                <Power className="size-3.5" />
                              </Button>
                              <Button
                                size="sm"
                                variant="ghost"
                                className="size-8 p-0 text-destructive hover:text-destructive"
                                aria-label={t("common.delete")}
                                onClick={() => openDelete({ id: row.id, name: itemName(row) })}
                              >
                                <Trash2 className="size-4" />
                              </Button>
                            </div>
                          )}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        {/* One table for both tabs: live movements, or the cancelled ones only */}
        <TabsContent value={tab === "voided" ? "voided" : "movements"} className="mt-4 space-y-3">
          <SearchBar
            value={movesQuery}
            onChange={setMovesQuery}
            placeholder={t("inv.searchMovements")}
            clearLabel={t("inv.clearSearch")}
          />
          {tab === "movements" && (
            <label className="flex min-h-11 w-max cursor-pointer items-center gap-2 text-sm">
              <input
                type="checkbox"
                className="size-4 accent-primary"
                checked={manualOnly}
                onChange={(e) => setManualOnly(e.target.checked)}
              />
              {t("inv.manualOnly")}
            </label>
          )}
          {canPick && picked.length > 0 && (
            <div className="flex flex-wrap items-center gap-2 rounded-lg border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
              <span className="font-medium">
                {t("inv.pickedCount").replace("{n}", String(picked.length))}
              </span>
              <Button size="sm" variant="destructive" onClick={() => setBulkVoidOpen(true)}>
                {t("inv.voidPicked").replace("{n}", String(picked.length))}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setPicked([])}>
                {t("inv.clearPicked")}
              </Button>
            </div>
          )}
          {((tab === "voided" ? voidedMovements.data : movements.data) ?? []).length === 0 ? (
            <EmptyState message={t(tab === "voided" ? "inv.emptyVoided" : "inv.emptyMovements")} />
          ) : filteredMovements.length === 0 ? (
            <EmptyState message={t("inv.noMatches")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card shadow-sm">
              <Table className="min-w-[820px] text-xs">
                <TableHeader className="bg-muted/45">
                  <TableRow className="hover:bg-muted/45">
                    {canPick && (
                      <TableHead className="h-9 w-10 px-2 text-center">
                        <Checkbox
                          checked={allPicked}
                          disabled={pickable.length === 0}
                          onCheckedChange={(on) =>
                            setPicked(on ? pickable.map((row) => row.id) : [])
                          }
                          aria-label={t("inv.pickAll")}
                        />
                      </TableHead>
                    )}
                    <TableHead className="h-9 w-40 whitespace-nowrap px-3 text-center font-semibold">
                      {t("inv.date")}
                    </TableHead>
                    <TableHead className="h-9 min-w-48 px-3 text-start font-semibold">
                      {t("inv.item")}
                    </TableHead>
                    <TableHead className="h-9 w-32 whitespace-nowrap px-2 text-center font-semibold">
                      {t("inv.type")}
                    </TableHead>
                    <TableHead className="h-9 w-24 whitespace-nowrap px-2 text-center font-semibold">
                      {t("inv.qty")}
                    </TableHead>
                    <TableHead className="h-9 w-28 whitespace-nowrap px-2 text-center font-semibold">
                      {t("inv.balance")}
                    </TableHead>
                    <TableHead className="h-9 min-w-52 px-3 text-start font-semibold">
                      {t("inv.reason")}
                    </TableHead>
                    {canAdjust && (
                      <TableHead className="w-40 whitespace-nowrap text-center">
                        {t("common.actions")}
                      </TableHead>
                    )}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {filteredMovements.map((row) => (
                    <TableRow
                      key={row.id}
                      className={`h-11 even:bg-muted/20 ${row.voided_at ? "text-muted-foreground" : ""} ${picked.includes(row.id) ? "bg-destructive/5" : ""}`}
                    >
                      {canPick && (
                        <TableCell className="w-10 px-2 text-center">
                          {canVoidMovement(row) && (
                            <Checkbox
                              checked={picked.includes(row.id)}
                              onCheckedChange={(on) => togglePick(row.id, on === true)}
                              aria-label={t("inv.pickRow")}
                            />
                          )}
                        </TableCell>
                      )}
                      <TableCell className="w-40 whitespace-nowrap px-3 py-1.5 text-center tabular-nums">
                        {formatDateTime(row.created_at, lang)}
                      </TableCell>
                      <TableCell className="min-w-48 px-3 py-1.5 font-medium">
                        {itemName(row.inventory_items)}
                      </TableCell>
                      <TableCell className="w-32 px-2 py-1.5 text-center">
                        <Badge variant="outline" className="h-5 px-1.5 text-[10px]">
                          {t(`inv.type.${row.movement_type}`)}
                        </Badge>
                        {row.reference_type === "stock_reset" && (
                          <Badge variant="secondary" className="ms-1 h-5 px-1.5 text-[10px]">
                            {t("inv.stockReset")}
                          </Badge>
                        )}
                        {row.voided_at && (
                          <Badge variant="destructive" className="ms-1 h-5 px-1.5 text-[10px]">
                            {t("inv.voided")}
                          </Badge>
                        )}
                        {row.movement_type === "waste" && (
                          <span className="mt-1 block text-[10px] text-muted-foreground">
                            {(() => {
                              const b =
                                WASTE_BEARERS[(row.waste_bearer ?? "business") as WasteBearer];
                              const who = lang === "ar" ? b.ar : b.en;
                              const name = row.waste_staff_id
                                ? staffNames.get(row.waste_staff_id)
                                : null;
                              return `${lang === "ar" ? "على" : "Borne by"}: ${name ?? who}`;
                            })()}
                          </span>
                        )}
                      </TableCell>
                      <TableCell
                        className={`w-24 px-2 py-1.5 text-center font-semibold tabular-nums ${
                          row.voided_at
                            ? "text-muted-foreground line-through"
                            : Number(row.quantity) < 0
                              ? "text-destructive"
                              : "text-emerald-600"
                        }`}
                      >
                        {Number(row.quantity) > 0 ? "+" : ""}
                        {Number(row.quantity)}
                      </TableCell>
                      <TableCell className="w-28 px-2 py-1.5 text-center tabular-nums">
                        {Number(row.balance_after)}
                      </TableCell>
                      <TableCell
                        className="max-w-72 min-w-52 truncate px-3 py-1.5 text-muted-foreground"
                        title={row.reason ?? undefined}
                      >
                        {row.reason ?? "—"}
                        {row.voided_at && (
                          <span
                            className="block truncate text-[10px] text-destructive"
                            title={row.void_reason ?? undefined}
                          >
                            {t("inv.voidedOn")} {formatDateTime(row.voided_at, lang)}:{" "}
                            {row.void_reason}
                          </span>
                        )}
                      </TableCell>
                      {canAdjust && (
                        <TableCell className="w-40 text-center">
                          {canEditMovement(row) && (
                            <div className="flex items-center justify-center gap-1">
                              <Button
                                size="sm"
                                variant="ghost"
                                onClick={() =>
                                  setMoveEdit({
                                    id: row.id,
                                    item: itemName(row.inventory_items),
                                    type: t(`inv.type.${row.movement_type}`),
                                    created_at: row.created_at,
                                    quantity: String(Math.abs(Number(row.quantity))),
                                    unit_cost: String(row.unit_cost ?? 0),
                                    reason: "",
                                  })
                                }
                              >
                                {t("common.edit")}
                              </Button>
                              {canVoidMovement(row) && (
                                <Button
                                  size="sm"
                                  variant="ghost"
                                  className="text-destructive hover:text-destructive"
                                  onClick={() =>
                                    setMoveVoid({
                                      id: row.id,
                                      item: itemName(row.inventory_items),
                                      type: t(`inv.type.${row.movement_type}`),
                                      created_at: row.created_at,
                                      quantity: Number(row.quantity),
                                      stockAfter: stockAfterVoid(
                                        stockMap.get(row.item_id) ?? 0,
                                        row.quantity,
                                      ),
                                      reason: "",
                                    })
                                  }
                                >
                                  {t("inv.voidMovement")}
                                </Button>
                              )}
                            </div>
                          )}
                        </TableCell>
                      )}
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>
      </Tabs>

      <InventoryItemDialog
        open={itemDialog}
        onOpenChange={setItemDialog}
        initial={itemForm}
        onSaved={refreshStock}
      />

      <WasteLogDialog
        open={wasteDialog}
        onOpenChange={setWasteDialog}
        items={(items.data ?? []).filter((i) => i.is_active)}
        canChargeStaff={canChargeStaff}
      />

      <Dialog open={moveDialog} onOpenChange={setMoveDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("inv.newMovement")}</DialogTitle>
          </DialogHeader>
          <div className="grid gap-3">
            <div>
              <Label>{t("inv.item")}</Label>
              <Select value={moveItem} onValueChange={setMoveItem}>
                <SelectTrigger className="mt-1">
                  <SelectValue placeholder={t("inv.selectItem")} />
                </SelectTrigger>
                <SelectContent>
                  {(items.data ?? []).map((i) => (
                    <SelectItem key={i.id} value={i.id}>
                      {itemName(i)} ({i.unit})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div>
              <Label>{t("inv.type")}</Label>
              <Select
                value={moveType}
                onValueChange={(value) => setMoveType(value as (typeof MOVE_TYPES)[number])}
              >
                <SelectTrigger className="mt-1">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {availableTypes.map((type) => (
                    <SelectItem key={type} value={type}>
                      {t(`inv.type.${type}`)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            {moveType === "purchase" && (
              <div>
                <Label>{t("inv.totalCost")}</Label>
                <Input
                  className="mt-1 text-end font-mono tabular-nums"
                  inputMode="decimal"
                  value={moveTotal}
                  onChange={(e) => {
                    const value = e.target.value;
                    setMoveTotal(value);
                    const derived = deriveUnitCost(value, moveQty);
                    if (derived) setMoveCost(derived);
                  }}
                />
              </div>
            )}
            <div>
              <Label>
                {moveType === "stocktake"
                  ? t("inv.countedQty")
                  : moveType === "purchase"
                    ? t("inv.receivedQty")
                    : t("inv.qty")}
              </Label>
              <Input
                className="mt-1 text-end font-mono tabular-nums"
                inputMode="decimal"
                value={moveQty}
                onChange={(e) => {
                  const value = e.target.value;
                  setMoveQty(value);
                  const derived = deriveUnitCost(moveTotal, value);
                  if (derived) setMoveCost(derived);
                }}
              />
              {moveType === "adjustment" && (
                <p className="mt-1 text-xs text-muted-foreground">{t("inv.adjustHint")}</p>
              )}
            </div>
            {moveType === "purchase" && (
              <div>
                <Label>{t("inv.unitCost")}</Label>
                <Input
                  className="mt-1 text-end font-mono tabular-nums"
                  inputMode="decimal"
                  value={moveCost}
                  onChange={(e) => setMoveCost(e.target.value)}
                />
                {deriveUnitCost(moveTotal, moveQty) && (
                  <p className="mt-1 font-mono text-xs tabular-nums text-muted-foreground">
                    {t("inv.computedUnitCost")
                      .replace(
                        "{price}",
                        formatMoney(Number(deriveUnitCost(moveTotal, moveQty)), currency, lang),
                      )
                      .replace(
                        "{unit}",
                        (items.data ?? []).find((i) => i.id === moveItem)?.unit ?? "",
                      )}
                  </p>
                )}
              </div>
            )}
            <div>
              <Label>{t("inv.reason")}</Label>
              <Input
                className="mt-1"
                value={moveReason}
                onChange={(e) => setMoveReason(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setMoveDialog(false)}>
              {t("common.cancel")}
            </Button>
            <Button onClick={() => submitMovement.mutate()} disabled={submitMovement.isPending}>
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Bulk / quick raw item creator with inline opening balances */}
      <Dialog open={bulkDialog} onOpenChange={setBulkDialog}>
        <DialogContent className="max-w-5xl">
          <DialogHeader>
            <DialogTitle>{t("inv.bulkTitle")}</DialogTitle>
          </DialogHeader>
          <p className="text-xs text-muted-foreground">{t("inv.bulkHint")}</p>
          <div className="max-h-[60vh] overflow-auto rounded-lg border border-border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="min-w-40 text-start">{t("menu.nameAr")}</TableHead>
                  <TableHead className="min-w-40 text-start">{t("menu.nameEn")}</TableHead>
                  <TableHead className="w-28 text-center">{t("inv.unit")}</TableHead>
                  <TableHead className="w-32 text-end">{t("inv.totalCostShort")}</TableHead>
                  <TableHead className="w-32 text-end">{t("inv.totalQtyShort")}</TableHead>
                  <TableHead className="w-32 text-end">{t("inv.unitCost")}</TableHead>
                  <TableHead className="w-28 text-end">{t("inv.minQty")}</TableHead>
                  <TableHead className="w-16 text-center" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {bulkRows.map((row, index) => {
                  const update = (patch: Partial<BulkRow>) =>
                    setBulkRows((rows) =>
                      rows.map((r, i) => (i === index ? { ...r, ...patch } : r)),
                    );
                  const isLast = index === bulkRows.length - 1;
                  const onEnter = (e: React.KeyboardEvent<HTMLInputElement>) => {
                    if (e.key === "Enter" && isLast) {
                      e.preventDefault();
                      setBulkRows((rows) => [...rows, { ...emptyBulkRow }]);
                    }
                  };
                  return (
                    <TableRow key={index}>
                      <TableCell className="min-w-40">
                        <Input
                          className="text-start"
                          value={row.name_ar}
                          onChange={(e) => update({ name_ar: e.target.value })}
                          onKeyDown={onEnter}
                        />
                      </TableCell>
                      <TableCell className="min-w-40">
                        <Input
                          className="text-start"
                          value={row.name}
                          onChange={(e) => update({ name: e.target.value })}
                          onKeyDown={onEnter}
                        />
                      </TableCell>
                      <TableCell className="w-28 text-center">
                        <Select value={row.unit} onValueChange={(value) => update({ unit: value })}>
                          <SelectTrigger>
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {UNITS.map((unit) => (
                              <SelectItem key={unit} value={unit}>
                                {unit}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </TableCell>
                      <TableCell className="w-32">
                        <Input
                          className="text-end font-mono tabular-nums"
                          inputMode="decimal"
                          value={row.total_cost}
                          onChange={(e) => {
                            const total_cost = e.target.value;
                            const derived = deriveUnitCost(total_cost, row.opening_qty);
                            update({ total_cost, ...(derived ? { cost_per_unit: derived } : {}) });
                          }}
                          onKeyDown={onEnter}
                        />
                      </TableCell>
                      <TableCell className="w-32">
                        <Input
                          className="text-end font-mono tabular-nums"
                          inputMode="decimal"
                          value={row.opening_qty}
                          onChange={(e) => {
                            const opening_qty = e.target.value;
                            const derived = deriveUnitCost(row.total_cost, opening_qty);
                            update({ opening_qty, ...(derived ? { cost_per_unit: derived } : {}) });
                          }}
                          onKeyDown={onEnter}
                        />
                      </TableCell>
                      <TableCell className="w-32">
                        <Input
                          className="text-end font-mono tabular-nums"
                          inputMode="decimal"
                          value={row.cost_per_unit}
                          onChange={(e) => update({ cost_per_unit: e.target.value })}
                          onKeyDown={onEnter}
                        />
                      </TableCell>
                      <TableCell className="w-28">
                        <Input
                          className="text-end font-mono tabular-nums"
                          inputMode="decimal"
                          value={row.min_qty}
                          onChange={(e) => update({ min_qty: e.target.value })}
                          onKeyDown={onEnter}
                        />
                      </TableCell>
                      <TableCell className="w-16 text-center">
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-destructive hover:text-destructive"
                          aria-label={t("common.delete")}
                          disabled={bulkRows.length === 1}
                          onClick={() => setBulkRows((rows) => rows.filter((_, i) => i !== index))}
                        >
                          <Trash2 className="size-4" />
                        </Button>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
          <DialogFooter className="flex-wrap gap-2">
            <Button
              variant="outline"
              onClick={() => setBulkRows((rows) => [...rows, { ...emptyBulkRow }])}
            >
              {t("inv.bulkAddRow")}
            </Button>
            <Button onClick={() => bulkSave.mutate()} disabled={bulkSave.isPending}>
              {t("inv.bulkSave")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Raw item deletion: plain confirm when unused, cascade choices when linked to recipes */}
      <AlertDialog
        open={Boolean(itemToDelete)}
        onOpenChange={(open) => {
          if (!open) {
            setItemToDelete(null);
            setDeleteUsage(null);
          }
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {linkedCount > 0 ? t("inv.deleteLinkedTitle") : t("inv.deleteItemTitle")}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {linkedCount > 0
                ? t("inv.deleteLinkedBody").replace("{name}", itemToDelete?.name ?? "")
                : t("inv.deleteItemQ").replace("{name}", itemToDelete?.name ?? "")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          {linkedCount > 0 && (
            <div className="space-y-3 text-sm">
              {(deleteUsage?.products ?? []).length > 0 && (
                <div>
                  <p className="font-medium">{t("inv.linkedProducts")}</p>
                  <ul className="mt-1 list-disc space-y-1 ps-5 text-muted-foreground">
                    {(deleteUsage?.products ?? []).map((row) => (
                      <li key={row.id} className="text-start">
                        {itemName(row)}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              {(deleteUsage?.modifiers ?? []).length > 0 && (
                <div>
                  <p className="font-medium">{t("inv.linkedModifiers")}</p>
                  <ul className="mt-1 list-disc space-y-1 ps-5 text-muted-foreground">
                    {(deleteUsage?.modifiers ?? []).map((row) => (
                      <li key={row.id} className="text-start">
                        {itemName(row)}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          )}
          <AlertDialogFooter className="flex-col gap-2 sm:flex-row">
            <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
            {linkedCount > 0 && (
              <Button
                variant="outline"
                disabled={disableItem.isPending}
                onClick={() => itemToDelete && disableItem.mutate(itemToDelete.id)}
              >
                {t("inv.disableOnly")}
              </Button>
            )}
            <Button
              variant="destructive"
              disabled={deleteItem.isPending}
              onClick={() =>
                itemToDelete && deleteItem.mutate({ id: itemToDelete.id, unlink: linkedCount > 0 })
              }
            >
              {linkedCount > 0 ? t("inv.deleteUnlink") : t("common.delete")}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Edit a manual movement; the database rebalances stock atomically */}
      <Dialog open={Boolean(moveEdit)} onOpenChange={(open) => !open && setMoveEdit(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("inv.editMovement")}</DialogTitle>
          </DialogHeader>
          {moveEdit && (
            <div className="space-y-3">
              <div className="rounded-lg border border-border bg-muted/30 p-3 text-sm">
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.item")}</span>
                  <span className="font-medium">{moveEdit.item}</span>
                </div>
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.type")}</span>
                  <span>{moveEdit.type}</span>
                </div>
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.date")}</span>
                  <span className="font-mono tabular-nums">
                    {formatDateTime(moveEdit.created_at, lang)}
                  </span>
                </div>
              </div>
              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <Label>{t("inv.newQty")}</Label>
                  <Input
                    className="mt-1 text-end font-mono tabular-nums"
                    inputMode="decimal"
                    value={moveEdit.quantity}
                    onChange={(e) => setMoveEdit({ ...moveEdit, quantity: e.target.value })}
                  />
                </div>
                <div>
                  <Label>{t("inv.unitCost")}</Label>
                  <Input
                    className="mt-1 text-end font-mono tabular-nums"
                    inputMode="decimal"
                    value={moveEdit.unit_cost}
                    onChange={(e) => setMoveEdit({ ...moveEdit, unit_cost: e.target.value })}
                  />
                </div>
              </div>
              <div>
                <Label>{t("inv.editReason")}</Label>
                <Textarea
                  className="mt-1 text-start"
                  rows={3}
                  value={moveEdit.reason}
                  onChange={(e) => setMoveEdit({ ...moveEdit, reason: e.target.value })}
                />
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setMoveEdit(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              onClick={() => editMovement.mutate()}
              disabled={editMovement.isPending || !moveEdit?.reason.trim()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Cancel the ticked movements together; all or nothing */}
      <Dialog open={bulkVoidOpen} onOpenChange={setBulkVoidOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("inv.voidPicked").replace("{n}", String(picked.length))}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div className="max-h-64 overflow-y-auto rounded-lg border border-border">
              <Table className="text-xs">
                <TableHeader className="bg-muted/45">
                  <TableRow className="hover:bg-muted/45">
                    <TableHead className="h-8 px-3 text-start">{t("inv.item")}</TableHead>
                    <TableHead className="h-8 w-20 text-center">{t("inv.movements")}</TableHead>
                    <TableHead className="h-8 w-20 text-center">{t("inv.qty")}</TableHead>
                    <TableHead className="h-8 w-28 text-center">
                      {t("inv.stockAfterVoid")}
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pickedByItem.map((g) => (
                    <TableRow key={g.item_id}>
                      <TableCell className="px-3 py-1.5 font-medium">
                        {pickedNames.get(g.item_id)}
                      </TableCell>
                      <TableCell className="py-1.5 text-center tabular-nums">{g.count}</TableCell>
                      <TableCell className="py-1.5 text-center font-mono tabular-nums">
                        {g.quantity > 0 ? "+" : ""}
                        {g.quantity}
                      </TableCell>
                      <TableCell
                        className={`py-1.5 text-center font-mono font-semibold tabular-nums ${g.after < 0 ? "text-destructive" : ""}`}
                      >
                        {g.after}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            <p className="text-xs text-muted-foreground">{t("inv.voidPickedHint")}</p>
            {pickedByItem.some((g) => g.after < 0) && (
              <p className="rounded-md border border-destructive/40 bg-destructive/10 p-2 text-xs text-destructive">
                {t("inv.voidPickedNegative")}
              </p>
            )}
            <div>
              <Label>{t("inv.voidReason")}</Label>
              <Textarea
                className="mt-1 text-start"
                rows={3}
                value={bulkVoidReason}
                onChange={(e) => setBulkVoidReason(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setBulkVoidOpen(false)}>
              {t("common.cancel")}
            </Button>
            <Button
              variant="destructive"
              onClick={() => voidPicked.mutate()}
              disabled={
                voidPicked.isPending || picked.length === 0 || bulkVoidReason.trim().length < 3
              }
            >
              {t("inv.voidPicked").replace("{n}", String(picked.length))}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Cancel a manual movement; nothing is deleted */}
      <Dialog open={Boolean(moveVoid)} onOpenChange={(open) => !open && setMoveVoid(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("inv.voidMovement")}</DialogTitle>
          </DialogHeader>
          {moveVoid && (
            <div className="space-y-3">
              <div className="rounded-lg border border-border bg-muted/30 p-3 text-sm">
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.item")}</span>
                  <span className="font-medium">{moveVoid.item}</span>
                </div>
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.type")}</span>
                  <span>{moveVoid.type}</span>
                </div>
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.date")}</span>
                  <span className="font-mono tabular-nums">
                    {formatDateTime(moveVoid.created_at, lang)}
                  </span>
                </div>
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.qty")}</span>
                  <span className="font-mono tabular-nums">
                    {moveVoid.quantity > 0 ? "+" : ""}
                    {moveVoid.quantity}
                  </span>
                </div>
                <div className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{t("inv.stockAfterVoid")}</span>
                  <span
                    className={`font-mono font-semibold tabular-nums ${moveVoid.stockAfter < 0 ? "text-destructive" : ""}`}
                  >
                    {moveVoid.stockAfter}
                  </span>
                </div>
              </div>
              <p className="text-xs text-muted-foreground">{t("inv.voidHint")}</p>
              {moveVoid.stockAfter < 0 && (
                <p className="rounded-md border border-destructive/40 bg-destructive/10 p-2 text-xs text-destructive">
                  {t("inv.voidNegativeWarning")}
                </p>
              )}
              <div>
                <Label>{t("inv.voidReason")}</Label>
                <Textarea
                  className="mt-1 text-start"
                  rows={3}
                  value={moveVoid.reason}
                  onChange={(e) => setMoveVoid({ ...moveVoid, reason: e.target.value })}
                />
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setMoveVoid(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              variant="destructive"
              onClick={() => voidMovement.mutate()}
              disabled={voidMovement.isPending || (moveVoid?.reason.trim().length ?? 0) < 3}
            >
              {t("inv.voidMovement")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
