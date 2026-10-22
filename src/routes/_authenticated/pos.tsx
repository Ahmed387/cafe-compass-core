import { InfoTip } from "@/components/shared/InfoTip";
import { ShiftPaymentBreakdown } from "@/modules/operations/ShiftLedgerKpis";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Banknote, Calculator, CircleAlert, Coins, Minus, Plus, Printer, ReceiptText, Search, ShieldCheck, ShoppingCart, TicketPercent, UserPlus, Users, Wallet, X } from "lucide-react";

import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

import { Sheet, SheetContent, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";

import { supabase } from "@/integrations/supabase/client";
import { CollapsibleSection, KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import { RefundBearerList, useRefundsToDecide } from "@/components/pos/RefundBearerList";
import { useFinancialEngine } from "@/core/hooks/useFinancialEngine";
import { accrueCashback, nextTier, parseCashbackConfig } from "@/lib/cashback-tiers";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence, printBaristaTicket, printReceipt } from "@/lib/receipt";
import { printShiftCloseReport } from "@/lib/shift-close-print";
import { useProductImageUrls } from "@/lib/product-images";
import { softOpeningImage, type ServeType } from "@/lib/soft-opening-catalog";
import { CustomerSuggestionList } from "@/modules/operations/CustomerSuggestionList";
import { customerLookupTerm, usePosCustomerLookup } from "@/modules/operations/pos-customer-lookup";
import { addTender, singleTender, summarizePayments, toServerPayments, type TenderRow } from "@/modules/operations/payment-split";
import { toggleExtraOnOneUnit } from "@/modules/operations/cart-extras";
import { SoldOutToggle } from "@/modules/operations/SoldOutToggle";
import { BarLowStockAlert, LowStockCardBadge, useBarLowStock } from "@/modules/supply/bar-low-stock";
import {
  ShiftExpenseDialog,
  ShiftRosterDialog,
  StaffPicker,
  useLastRetainedFloat,
  useShiftRoster,
  useStaffCandidates,
  type ShortageMode,
} from "@/modules/operations/shift-workflow";

export const Route = createFileRoute("/_authenticated/pos")({
  head: () => ({
    meta: [
      { title: "Cashier — 20s Coffee" },
      {
        name: "description",
        content: "Take orders, apply add-ons, split payments and manage cash shifts at 20s Coffee.",
      },
      { property: "og:title", content: "Cashier — 20s Coffee" },
      {
        property: "og:description",
        content: "Point of sale terminal with shift and cash control.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: PosPage,
});

type CartModifier = { option_id: string; name: string; price_delta: number };
type CartLine = {
  key: string;
  product_id: string;
  product_name: string;
  size_id: string | null;
  size_name: string | null;
  unit_price: number;
  /** Original price before the active offer; drives the strike-through. */
  original_price?: number | undefined;
  offer_title?: string | null | undefined;
  offer_double?: boolean | undefined;
  /** Set for offer/bundle lines so the server can re-price and report them. */
  offer_id?: string | null | undefined;
  bundle_key?: string | null | undefined;
  is_taxable: boolean;
  quantity: number;
  modifiers: CartModifier[];
  /** Free-typed item with no catalog product. */
  custom?: boolean | undefined;
};

type BundleOffer = {
  id: string;
  title: string;
  offer_price: number;
  base_price: number;
  image_path: string | null;
  double_points: boolean;
  items: Array<{ product_id: string; quantity: number }>;
};

type ProductRow = {
  id: string;
  name: string;
  name_ar: string | null;
  base_price: number;
  image_url: string | null;
  is_taxable: boolean;
  is_available: boolean;
  track_stock: boolean;
  category_id: string | null;
  product_sizes: Array<{
    id: string;
    name: string;
    name_ar: string | null;
    price_delta: number;
    is_default: boolean;
    is_active: boolean;
  }>;
  product_modifier_groups: Array<{
    modifier_groups: {
      id: string;
      name: string;
      name_ar: string | null;
      min_select: number;
      max_select: number;
      is_active: boolean;
      modifier_options: Array<{
        id: string;
        name: string;
        name_ar: string | null;
        price_delta: number;
        is_active: boolean;
      }>;
    } | null;
  }>;
};

type PayRow = TenderRow;

function tenderName(key: string, name: string, lang: "ar" | "en") {
  if (key === "cash") return lang === "ar" ? "💵 كاش" : "💵 Cash";
  if (key === "instapay") return lang === "ar" ? "📱 إنستاباي" : "📱 InstaPay";
  if (key === "wallet") return lang === "ar" ? "👛 محفظة إلكترونية" : "👛 Wallet";
  if (key === "visa" || key === "card") return lang === "ar" ? "💳 فيزا" : "💳 Card";
  return name;
}

function newPayRow(methodKey: string, amount = ""): PayRow {
  return {
    id: `${methodKey}-${Math.random().toString(36).slice(2, 8)}`,
    methodKey,
    amount,
  };
}

function PosPage() {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const isSuperAdmin = me?.roleNames.includes("Super Admin") ?? false;
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  const label = (en: string, ar: string | null | undefined) => (lang === "ar" ? ar || en : en);
  const navigate = Route.useNavigate();

  const [categoryId, setCategoryId] = useState<string>("all");
  const [cart, setCart] = useState<CartLine[]>([]);
  const [orderType, setOrderType] = useState<"dine_in" | "takeaway" | "delivery">("dine_in");
  const [discount, setDiscount] = useState("");
  const [discountReason, setDiscountReason] = useState("");
  const [discountMode, setDiscountMode] = useState<"amount" | "percent">("amount");
  const [orderNote, setOrderNote] = useState("");
  const [customerName, setCustomerName] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");
  const [customerQuery, setCustomerQuery] = useState("");
  const [customerToolsOpen, setCustomerToolsOpen] = useState(false);
  const [customer, setCustomer] = useState<{
    id: string;
    code: string;
    name: string;
    phone: string | null;
    wallet_balance: number;
    cashback_progress: number;
    /** Visit stamps toward the next free drink. */
    points_balance?: number | null;
  } | null>(null);
  /** Cart line the customer gets free with their visit reward (one unit). */
  const [rewardLineKey, setRewardLineKey] = useState<string | null>(null);
  const [configProduct, setConfigProduct] = useState<ProductRow | null>(null);
  const [configSize, setConfigSize] = useState<string>("");
  const [configMods, setConfigMods] = useState<Record<string, CartModifier>>({});
  const [productSearch, setProductSearch] = useState("");
  const [extrasLineKey, setExtrasLineKey] = useState<string | null>(null);
  const [payOpen, setPayOpen] = useState(false);
  const [partnerId, setPartnerId] = useState<string>("");
  const [partnerMode, setPartnerMode] = useState<"paid" | "tab">("paid");
  const [payRows, setPayRows] = useState<PayRow[]>([]);
  const [cashReceived, setCashReceived] = useState("");
  const [openCashOpen, setOpenCashOpen] = useState(false);
  const [openingCash, setOpeningCash] = useState("");
  const [closeOpen, setCloseOpen] = useState(false);
  const [forceCloseOpen, setForceCloseOpen] = useState(false);
  const [closingCash, setClosingCash] = useState("");
  const [closeNotes, setCloseNotes] = useState("");
  const [retainedFloat, setRetainedFloat] = useState("");
  const [shortageMode, setShortageMode] = useState<ShortageMode>("split");
  const [shortageStaffId, setShortageStaffId] = useState("");
  const [venueReason, setVenueReason] = useState("");
  const [rosterIds, setRosterIds] = useState<string[]>([]);
  const [rosterOpen, setRosterOpen] = useState(false);
  const [expenseOpen, setExpenseOpen] = useState(false);
  const [lastOrder, setLastOrder] = useState<string | null>(null);
  const [customOpen, setCustomOpen] = useState(false);
  const [customName, setCustomName] = useState("");
  const [customPrice, setCustomPrice] = useState("");
  const [customQty, setCustomQty] = useState("1");
  function addCustomItem() {
    const name = customName.trim();
    const price = Math.round(Number(customPrice) * 100) / 100;
    const qty = Math.floor(Number(customQty));
    if (!name || name.length > 80) return void toast.error(lang === "ar" ? "اكتب اسم الصنف" : "Enter the item name");
    if (!(price > 0) || price > 100000) return void toast.error(lang === "ar" ? "السعر غير صحيح" : "Invalid price");
    if (!(qty >= 1) || qty > 999) return void toast.error(lang === "ar" ? "الكمية غير صحيحة" : "Invalid quantity");
    setCart((prev) => [
      ...prev,
      {
        key: `custom-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
        product_id: "",
        product_name: name,
        size_id: null,
        size_name: null,
        unit_price: price,
        is_taxable: true,
        quantity: qty,
        modifiers: [],
        custom: true,
      },
    ]);
    setCustomName("");
    setCustomPrice("");
    setCustomQty("1");
    setCustomOpen(false);
  }
  const [bundleLightbox, setBundleLightbox] = useState<{ src: string; alt: string } | null>(null);

  // Escape closes the combo image preview.
  useEffect(() => {
    if (!bundleLightbox) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setBundleLightbox(null);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [bundleLightbox]);

  const canUse = can("pos.view") || can("pos.create_order");

  const shift = useQuery({
    queryKey: ["open-shift", currentBranchId, me?.profile.id ?? null],
    enabled: Boolean(currentBranchId && me),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select("id, opening_cash, opened_at, branch_id, status")
        .eq("branch_id", currentBranchId!)
        .eq("user_id", me!.profile.id)
        .eq("status", "open")
        .order("opened_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (error) throw error;
      if (data) return data;
      // Cashier added to the shift crew (not the opener) still works and closes that shift.
      const { data: staffed, error: staffErr } = await supabase
        .from("shift_staff")
        .select("shifts!inner(id, opening_cash, opened_at, branch_id, status)")
        .eq("staff_id", me!.profile.id)
        .eq("shifts.branch_id", currentBranchId!)
        .eq("shifts.status", "open")
        .limit(1)
        .maybeSingle();
      if (staffErr) return null;
      const s = (staffed as { shifts?: unknown } | null)?.shifts;
      return (Array.isArray(s) ? s[0] : s) as typeof data ?? null;
    },
  });

  // Failsafe: any shift still open on this branch (possibly another cashier's ghost record).
  const stuckShift = useQuery({
    queryKey: ["stuck-shift", currentBranchId],
    enabled: Boolean(currentBranchId && me) && !shift.data && !shift.isLoading,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select("id, opening_cash, opened_at, user_id, user_profiles!shifts_user_id_fkey(display_name, first_name)")
        .eq("branch_id", currentBranchId!)
        .eq("status", "open")
        .order("opened_at", { ascending: true })
        .limit(1)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
  });



  // Live drawer preview so the cashier can count cash before closing.
  const cashPreview = useQuery({
    queryKey: ["shift-cash", shift.data?.id ?? null],
    enabled: Boolean(shift.data?.id) && closeOpen,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("shift_expected_cash", {
        _shift_id: shift.data!.id,
      });
      if (error) throw error;
      return data as {
        opening_cash: number;
        cash_in: number;
        cash_refunds: number;
        shift_expenses?: number;
        expected_cash: number;
        sales_total: number;
        orders_count: number;
      };
    },
  });

  const roster = useShiftRoster(shift.data?.id);
  const staffCandidates = useStaffCandidates(Boolean(shift.data?.id) && closeOpen);
  // Payment totals for the printable close report (same engine as the on-screen breakdown).
  const closeEngine = useFinancialEngine({
    branchId: currentBranchId,
    shiftIds: shift.data?.id && closeOpen ? [shift.data.id] : [],
  });
  const lastFloat = useLastRetainedFloat(currentBranchId);
  // Pre-fill the opening float with what the previous shift left in the drawer.
  useEffect(() => {
    if (!shift.data && lastFloat.data != null && openingCash === "") setOpeningCash(String(lastFloat.data));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lastFloat.data, shift.data]);

  // Refunds & waste recorded on this shift (item-level refunds included).
  const shiftRefunds = useQuery({
    queryKey: ["shift-refunds", shift.data?.id ?? null],
    enabled: Boolean(shift.data?.id) && closeOpen,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("order_refunds")
        .select("amount, method_key, items_payload")
        .eq("shift_id", shift.data!.id)
        .eq("status", "active");
      if (error) throw error;
      const rows = data ?? [];
      let total = 0;
      let cash = 0;
      let waste = 0;
      for (const row of rows) {
        total += Number(row.amount);
        if ((row.method_key ?? "cash") === "cash") cash += Number(row.amount);
        for (const entry of (row.items_payload ?? []) as Array<{
          disposition?: string;
          quantity?: number;
          unit_cost?: number | string;
        }>) {
          if (entry.disposition === "waste") {
            waste += Number(entry.unit_cost ?? 0) * Number(entry.quantity ?? 0);
          }
        }
      }
      return { total, cash, waste, count: rows.length };
    },
  });

  // Refunds still waiting for the manager to say who bears them (blocks closing).
  const refundsToDecide = useRefundsToDecide(shift.data?.id, closeOpen);

  const categories = useQuery({
    queryKey: ["pos-categories"],
    enabled: canUse,
    // Keep the cashier screen in sync with menu edits made in another tab.
    refetchInterval: 8000,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("categories")
        .select("id, name, name_ar")
        .eq("is_active", true)
        .order("display_order");
      if (error) throw error;
      return data ?? [];
    },
  });

  const products = useQuery({
    queryKey: ["pos-products"],
    enabled: canUse,
    refetchInterval: 8000,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("products")
        .select(
          "id, name, name_ar, base_price, image_url, is_taxable, is_available, track_stock, category_id, product_sizes(id, name, name_ar, price_delta, is_default, is_active), product_modifier_groups(modifier_groups(id, name, name_ar, min_select, max_select, is_active, modifier_options(id, name, name_ar, price_delta, is_active)))",
        )
        .eq("is_active", true)
        .order("display_order");
      if (error) throw error;
      return (data ?? []) as unknown as ProductRow[];
    },
  });

  // Every active add-on group, attachable to any cart line (e.g. "Serve in Can").
  const allGroups = useQuery({
    queryKey: ["pos-all-modifier-groups"],
    enabled: canUse,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("modifier_groups")
        .select("id, name, name_ar, is_active, modifier_options(id, name, name_ar, price_delta, is_active)")
        .eq("is_active", true);
      if (error) throw error;
      return data ?? [];
    },
  });
  const extrasLine = cart.find((l) => l.key === extrasLineKey) ?? null;
  function toggleLineExtra(mod: CartModifier) {
    if (!extrasLineKey) return;
    const result = toggleExtraOnOneUnit(cart, extrasLineKey, mod, `${extrasLineKey.split("-x")[0]}-x${Date.now()}`);
    setCart(result.cart);
    setExtrasLineKey(result.key);
  }

  const productImages = useProductImageUrls(
    (products.data ?? []).map((p) => p.image_url).filter((p) => !p?.startsWith("soft:")),
  );
  const imageOf = (path: string | null) => {
    if (!path) return null;
    if (path.startsWith("soft:")) {
      const [, key = "", serve = "none"] = path.split(":");
      return softOpeningImage(key, serve as ServeType) || null;
    }
    return productImages.data?.get(path) ?? null;
  };

  // Ingredient list per product so the cashier can answer "what's in it?".
  const recipes = useQuery({
    queryKey: ["pos-recipes"],
    enabled: canUse,
    retry: false,
    refetchInterval: 8000,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("product_recipes")
        .select("product_id, quantity, inventory_items(name, name_ar, unit)");
      if (error) return new Map<string, string[]>();
      const map = new Map<string, string[]>();
      for (const row of data ?? []) {
        const item = row.inventory_items;
        if (!item) continue;
        const list = map.get(row.product_id) ?? [];
        list.push(`${label(item.name, item.name_ar)} · ${Number(row.quantity)} ${item.unit}`);
        map.set(row.product_id, list);
      }
      return map;
    },
  });

  // Products with no stock recipe cannot be sold: the server rejects them,
  // so the grid greys them out instead of letting the cashier hit an error.
  const recipeProducts = useQuery({
    queryKey: ["pos-recipe-products"],
    enabled: canUse,
    refetchInterval: 8000,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase.from("product_recipes").select("product_id");
      if (error) throw error;
      return new Set((data ?? []).map((row) => row.product_id));
    },
  });
  const hasRecipe = (productId: string) =>
    !recipeProducts.data ||
    recipeProducts.data.has(productId) ||
    (products.data ?? []).some((p) => p.id === productId && p.track_stock === false);

  const methods = useQuery({
    queryKey: ["payment-methods"],
    enabled: canUse,
    queryFn: async () => {
      // receiver_account: InstaPay handle / wallet number the customer pays to.
      // A database without that column must still load every tender (cash, InstaPay, wallet…).
      const withAccount = await supabase
        .from("payment_methods")
        .select("id, key, name, kind, receiver_account" as "id, key, name, kind")
        .eq("is_active", true)
        .order("name");
      if (!withAccount.error) return withAccount.data ?? [];
      const { data, error } = await supabase
        .from("payment_methods")
        .select("id, key, name, kind")
        .eq("is_active", true)
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const methodByKey = (key: string) => methods.data?.find((m) => m.key === key) ?? null;

  // Master switch: when off, no promotional price is shown or charged.
  const offersOn = useQuery({
    queryKey: ["pos-offers-enabled"],
    enabled: canUse,
    refetchInterval: 30000,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("offers_enabled", {});
      if (error) throw error;
      return Boolean(data);
    },
  });
  const promosOn = offersOn.data !== false;

  // Active promotional offers, auto-applied at the till. The server validates
  // them again inside create_pos_order, so this keeps the screen price in
  // parity with what will actually be charged.
  const offers = useQuery({
    queryKey: ["pos-active-offers"],
    enabled: canUse,
    refetchInterval: 30000,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const today = new Date().toISOString().slice(0, 10);
      const { data, error } = await supabase
        .from("product_offers")
        .select(
          "id, product_id, offer_type, title, offer_price, base_price_snapshot, image_path, double_points, ends_at, offer_bundle_items(product_id, quantity)",
        )
        .eq("is_active", true)
        .lte("starts_at", today);
      if (error) throw error;
      const singles = new Map<
        string,
        { id: string; price: number; title: string; double: boolean }
      >();
      const bundles: BundleOffer[] = [];
      for (const row of data ?? []) {
        if (row.ends_at && row.ends_at < today) continue;
        if (row.offer_type === "bundle") {
          bundles.push({
            id: row.id,
            title: row.title,
            offer_price: Number(row.offer_price),
            base_price: Number(row.base_price_snapshot),
            image_path: row.image_path,
            double_points: Boolean(row.double_points),
            items: (row.offer_bundle_items ?? []).map((it) => ({
              product_id: it.product_id,
              quantity: Number(it.quantity),
            })),
          });
          continue;
        }
        if (!row.product_id) continue;
        const current = singles.get(row.product_id);
        if (!current || Number(row.offer_price) < current.price) {
          singles.set(row.product_id, {
            id: row.id,
            price: Number(row.offer_price),
            title: row.title,
            double: Boolean(row.double_points),
          });
        }
      }
      return { singles, bundles };
    },
  });
  const offerFor = (productId: string) =>
    promosOn ? (offers.data?.singles.get(productId) ?? null) : null;
  const bundleOffers = promosOn ? (offers.data?.bundles ?? []) : [];

  const bundleImageUrls = useQuery({
    queryKey: ["pos-bundle-images", bundleOffers.map((b) => b.image_path).join("|")],
    enabled: bundleOffers.some((b) => b.image_path),
    queryFn: async () => {
      const paths = bundleOffers.map((b) => b.image_path).filter((p): p is string => Boolean(p));
      const map = new Map<string, string>();
      if (paths.length === 0) return map;
      const { data } = await supabase.storage.from("offer-images").createSignedUrls(paths, 3600);
      for (const row of data ?? []) {
        if (row.path && row.signedUrl) map.set(row.path, row.signedUrl);
      }
      return map;
    },
  });

  /** Sells at the offer price when one is active; keeps the original for the strike-through. */
  function priceWithOffer(productId: string, basePrice: number) {
    const offer = offerFor(productId);
    if (offer && offer.price < basePrice) {
      return {
        unit_price: offer.price,
        original_price: basePrice,
        offer_title: offer.title,
        offer_double: offer.double,
        offer_id: offer.id,
      };
    }
    return {
      unit_price: basePrice,
      original_price: undefined,
      offer_title: null,
      offer_double: false,
      offer_id: null,
    };
  }

  /**
   * Adds a whole combo to the cart: one line per constituent drink, all sharing
   * one bundle key. The screen price is the proportional share of the bundle
   * price; create_pos_order recomputes the same split to the piastre.
   */
  function addBundle(offer: BundleOffer) {
    const list = (products.data ?? []).filter((p) =>
      offer.items.some((it) => it.product_id === p.id),
    );
    if (list.length !== offer.items.length) {
      toast.error(t("menu.unavailable"));
      return;
    }
    const key = `bundle-${offer.id}-${Math.random().toString(36).slice(2, 8)}`;
    const baseTotal = offer.items.reduce((sum, it) => {
      const p = list.find((row) => row.id === it.product_id);
      return sum + Number(p?.base_price ?? 0) * it.quantity;
    }, 0);
    if (baseTotal <= 0) return;

    let allocated = 0;
    const lines: CartLine[] = offer.items.map((it, index) => {
      const p = list.find((row) => row.id === it.product_id)!;
      const lineBase = Number(p.base_price) * it.quantity;
      const share =
        index === offer.items.length - 1
          ? Math.round((offer.offer_price - allocated) * 100) / 100
          : Math.round(offer.offer_price * (lineBase / baseTotal) * 100) / 100;
      allocated += share;
      return {
        key: `${key}-${index}`,
        product_id: p.id,
        product_name: label(p.name, p.name_ar),
        size_id: null,
        size_name: null,
        unit_price: share / it.quantity,
        original_price: Number(p.base_price),
        offer_title: offer.title,
        offer_double: offer.double_points,
        offer_id: offer.id,
        bundle_key: key,
        is_taxable: p.is_taxable,
        quantity: it.quantity,
        modifiers: [],
      };
    });
    setCart((prev) => [...prev, ...lines]);
    toast.success(t("pos.bundleAdded"));
  }

  const searchQ = productSearch.trim().toLowerCase();
  const visibleProducts = searchQ
    ? (products.data ?? []).filter((p) =>
        [p.name, p.name_ar, p.id.slice(0, 8)].some((f) => (f ?? "").toLowerCase().includes(searchQ)),
      )
    : categoryId === "offers"
      ? []
      : (products.data ?? []).filter((p) => categoryId === "all" || p.category_id === categoryId);

  // Products whose sizes are only upgrades (e.g. Double) still sell their base as "Single".
  function needsBaseSize(product: ProductRow) {
    const sizes = product.product_sizes.filter((s) => s.is_active);
    return sizes.length > 0 && !sizes.some((s) => Number(s.price_delta) === 0);
  }

  const totals = useMemo(() => {
    let subtotal = 0;
    let offersDiscount = 0;
    let doubleValue = 0;
    for (const line of cart) {
      const mods = line.modifiers.reduce((sum, m) => sum + Number(m.price_delta), 0);
      const lineTotal = (Number(line.unit_price) + mods) * line.quantity;
      subtotal += lineTotal;
      if (line.original_price != null) {
        offersDiscount += Math.max(
          0,
          (Number(line.original_price) - Number(line.unit_price)) * line.quantity,
        );
      }
      if (line.offer_double) doubleValue += lineTotal;
    }
    const rawManual = Math.max(Number(discount) || 0, 0);
    const manualDiscount = Math.round(Math.min(discountMode === "percent" ? (subtotal * Math.min(rawManual, 100)) / 100 : rawManual, subtotal) * 100) / 100;
    const discountValue = Math.min(Math.max(manualDiscount, 0), subtotal);
    // Visit reward: one unit of the chosen line is free (add-ons stay paid).
    const rewardLine = rewardLineKey ? cart.find((l) => l.key === rewardLineKey && !l.custom && !l.bundle_key) : undefined;
    const rewardValue = rewardLine ? Math.min(Number(rewardLine.unit_price), Math.max(subtotal - discountValue, 0)) : 0;
    const tax = 0;
    const total = Math.round((subtotal - discountValue - rewardValue) * 100) / 100;
    return { subtotal, discountValue, manualDiscount, rewardValue, offersDiscount, doubleValue, tax, total };
  }, [cart, discount, discountMode, rewardLineKey]);

  const cashLine = payRows.find((row) => row.methodKey === "cash") ?? null;
  const cashDue = Number(cashLine?.amount) || 0;
  const change = Math.max(0, (Number(cashReceived) || 0) - cashDue);

  function resetOrder() {
    setCart([]);
    setRewardLineKey(null);
    setDiscount("");
    setDiscountReason("");
      setOrderNote("");
    setCustomerName("");
    setCustomerPhone("");
    setCustomer(null);
    setCustomerQuery("");
    setPayRows([]);
    setCashReceived("");
    setPartnerId("");
    setPartnerMode("paid");
    setOrderType("dine_in");
  }

  function addLine(line: Omit<CartLine, "key" | "quantity">) {
    const signature = `${line.product_id}|${line.size_id ?? ""}|${line.modifiers
      .map((m) => m.option_id)
      .sort()
      .join(",")}`;
    setCart((prev) => {
      const existing = prev.find((l) => l.key === signature);
      if (existing) {
        return prev.map((l) => (l.key === signature ? { ...l, quantity: l.quantity + 1 } : l));
      }
      return [...prev, { ...line, key: signature, quantity: 1 }];
    });
  }

  function activeGroups(product: ProductRow) {
    return product.product_modifier_groups
      .map((row) => row.modifier_groups)
      .filter((g): g is NonNullable<typeof g> => Boolean(g) && g!.is_active);
  }

  function pickProduct(product: ProductRow) {
    const sizes = product.product_sizes.filter((s) => s.is_active);
    const groups = activeGroups(product);
    if (sizes.length === 0 && groups.length === 0) {
      addLine({
        product_id: product.id,
        product_name: label(product.name, product.name_ar),
        size_id: null,
        size_name: null,
        ...priceWithOffer(product.id, Number(product.base_price)),
        is_taxable: product.is_taxable,
        modifiers: [],
      });
      return;
    }
    const defaultSize =
      sizes.find((s) => s.is_default) ?? (needsBaseSize(product) ? undefined : sizes[0]);
    setConfigProduct(product);
    setConfigSize(defaultSize?.id ?? "");
    setConfigMods({});
  }

  function confirmConfig() {
    if (!configProduct) return;
    const sizes = configProduct.product_sizes.filter((s) => s.is_active);
    const size = sizes.find((s) => s.id === configSize) ?? null;
    const mods = Object.values(configMods);
    for (const group of activeGroups(configProduct)) {
      const chosen = mods.filter((m) =>
        group.modifier_options.some((o) => o.id === m.option_id),
      ).length;
      if (chosen < group.min_select) {
        toast.error(`${label(group.name, group.name_ar)} — ${t("pos.chooseRequired")}`);
        return;
      }
    }
    addLine({
      product_id: configProduct.id,
      product_name: label(configProduct.name, configProduct.name_ar),
      size_id: size?.id ?? null,
      size_name: size ? label(size.name, size.name_ar) : null,
      ...priceWithOffer(
        configProduct.id,
        Number(configProduct.base_price) + Number(size?.price_delta ?? 0),
      ),
      is_taxable: configProduct.is_taxable,
      modifiers: mods,
    });
    setConfigProduct(null);
  }

  function toggleMod(
    group: { max_select: number; modifier_options: Array<{ id: string }> },
    mod: CartModifier,
  ) {
    setConfigMods((prev) => {
      const next = { ...prev };
      if (next[mod.option_id]) {
        delete next[mod.option_id];
        return next;
      }
      const groupIds = group.modifier_options.map((o) => o.id);
      const chosen = Object.keys(next).filter((id) => groupIds.includes(id));
      if (group.max_select === 1) {
        for (const id of chosen) delete next[id];
      } else if (chosen.length >= group.max_select) {
        toast.error(t("pos.maxReached"));
        return prev;
      }
      next[mod.option_id] = mod;
      return next;
    });
  }

  const openShift = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("open_shift_with_roster", {
        _branch_id: currentBranchId!,
        _opening_cash: Number(openingCash) || 0,
        _staff_ids: rosterIds,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setOpenCashOpen(false);
      setOpeningCash("");
      setRosterIds([]);
      await queryClient.invalidateQueries({ queryKey: ["open-shift"] });
      toast.success(t("pos.shiftOpened"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const closeShift = useMutation({
    mutationFn: async (
      attribution: { mode: ShortageMode; staffId: string | null; reason: string | null } | null,
    ) => {
      const { error } = await supabase.rpc("close_shift_handover", {
        _shift_id: shift.data!.id,
        _closing_cash: Number(closingCash) || 0,
        _retained_float: Number(retainedFloat) || 0,
        ...(attribution ? { _shortage_mode: attribution.mode } : {}),
        ...(attribution?.staffId ? { _shortage_staff_id: attribution.staffId } : {}),
        ...(attribution?.reason || closeNotes ? { _notes: attribution?.reason ?? closeNotes } : {}),
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setCloseOpen(false);
      setClosingCash("");
      setShortageMode("split");
      setShortageStaffId("");
      setVenueReason("");
      setRetainedFloat("");
      await queryClient.invalidateQueries({ queryKey: ["last-retained-float"] });
      setCloseNotes("");
      resetOrder();
      await queryClient.invalidateQueries({ queryKey: ["open-shift"] });
      await queryClient.invalidateQueries({ queryKey: ["stuck-shift"] });
      toast.success(t("pos.shiftClosed"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const closeShortage = cashPreview.data
    ? Math.round(((cashPreview.data.expected_cash ?? 0) - (Number(closingCash) || 0)) * 100) / 100
    : 0;
  const shortageStaff = (staffCandidates.data ?? []).filter(
    (person) => (roster.data ?? []).includes(person.id) || person.id === me?.profile.id,
  );
  const canAbsorbShortage =
    isSuperAdmin ||
    can("expenses.approve") ||
    (me?.roleNames ?? []).some((r) => r === "Manager" || r === "Partner");
  const trimmedVenueReason = venueReason.trim();
  const venueReasonValid =
    trimmedVenueReason.length >= 8 && (trimmedVenueReason.match(/[A-Za-zء-ي]/g)?.length ?? 0) >= 5;
  function requestClose() {
    if ((Number(retainedFloat) || 0) > (Number(closingCash) || 0)) {
      toast.error(lang === "ar" ? "الفكة المتبقية أكبر من المبلغ المعدود" : "Retained float exceeds counted cash");
      return;
    }
    if (closeShortage > 0) {
      if (shortageMode === "staff" && !shortageStaffId) {
        toast.error(lang === "ar" ? "اختر الموظف الذي سيتحمل العجز" : "Select the staff member who carries the shortage");
        return;
      }
      if (shortageMode === "split" && shortageStaff.length === 0) {
        toast.error(lang === "ar" ? "لا يوجد طاقم وردية لتوزيع العجز عليهم" : "No shift staff to split the shortage across");
        return;
      }
      if (shortageMode === "venue" && !venueReasonValid) {
        toast.error(lang === "ar" ? "اكتب سببًا واضحًا لتحميل العجز على المكان" : "Write a clear reason for the venue-absorbed shortage");
        return;
      }
      closeShift.mutate({
        mode: shortageMode,
        staffId: shortageMode === "staff" ? shortageStaffId : null,
        reason: shortageMode === "venue" ? trimmedVenueReason : null,
      });
      return;
    }
    closeShift.mutate(null);
  }

  // Print a clean, fully-expanded close report instead of printing the live form.
  function handlePrintClose() {
    const ar = lang === "ar";
    const preview = cashPreview.data;
    if (!preview || !shift.data) {
      toast.error(ar ? "بيانات الوردية لم تجهز بعد" : "Shift data is not ready yet");
      return;
    }
    const t = closeEngine.data?.totals;
    const tenderLabels: Array<{ key: "cash" | "instapay" | "visa" | "wallet" | "partner_tab"; ar: string; en: string }> = [
      { key: "cash", ar: "كاش", en: "Cash" },
      { key: "instapay", ar: "انستاباي", en: "InstaPay" },
      { key: "visa", ar: "فيزا", en: "Visa" },
      { key: "wallet", ar: "المحافظ / فودافون كاش", en: "Wallets" },
      { key: "partner_tab", ar: "على حساب الشريك", en: "Partner tab" },
    ];
    const counted = Number(closingCash) || 0;
    const float = Number(retainedFloat) || 0;
    const staffName = staffCandidates.data?.find((p) => p.id === shortageStaffId);
    const ok = printShiftCloseReport({
      lang: ar ? "ar" : "en",
      currency,
      branchName: me?.branches.find((b) => b.id === currentBranchId)?.name ?? null,
      cashierName: me?.profile.display_name ?? me?.profile.first_name ?? null,
      openedAt: shift.data.opened_at,
      tenders: tenderLabels.map((tl) => ({
        label: ar ? tl.ar : tl.en,
        amount: t?.tenders[tl.key] ?? 0,
        count: t?.tenderCounts[tl.key] ?? 0,
      })),
      refunds:
        shiftRefunds.data && shiftRefunds.data.count > 0
          ? { total: shiftRefunds.data.total, cash: shiftRefunds.data.cash, waste: shiftRefunds.data.waste }
          : null,
      cash: {
        opening: preview.opening_cash,
        cashIn: preview.cash_in,
        cashRefunds: preview.cash_refunds,
        drawerExpenses: Number(preview.shift_expenses ?? 0),
        salesTotal: preview.sales_total,
        ordersCount: preview.orders_count,
        expected: preview.expected_cash,
      },
      closingCash: counted,
      retainedFloat: float,
      variance: Math.round((counted - preview.expected_cash) * 100) / 100,
      shortage:
        closeShortage > 0
          ? {
              modeLabel:
                shortageMode === "split"
                  ? ar
                    ? "بالتساوي على طاقم الوردية"
                    : "Split across shift staff"
                  : shortageMode === "staff"
                    ? ar
                      ? "على موظف محدد"
                      : "Specific staff member"
                    : ar
                      ? "على المكان"
                      : "Absorbed by venue",
              detail:
                shortageMode === "staff"
                  ? (staffName?.name ?? null)
                  : shortageMode === "venue"
                    ? trimmedVenueReason
                    : null,
            }
          : null,
      notes: closeNotes.trim() || null,
    });
    if (!ok) toast.error(ar ? "المتصفح منع نافذة الطباعة — اسمح بالنوافذ المنبثقة" : "Popup blocked — allow popups to print");
  }

  // Emergency override: close a shift left open so the cashier is never blocked.
  const forceCloseShift = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("force_close_stuck_shift", {
        _branch_id: currentBranchId!,
        _reason: lang === "ar" ? "إغلاق وردية عالقة من شاشة الكاشير" : "Stuck shift closed from POS",
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setForceCloseOpen(false);
      await queryClient.invalidateQueries({ queryKey: ["open-shift"] });
      await queryClient.invalidateQueries({ queryKey: ["stuck-shift"] });
      await queryClient.invalidateQueries({ queryKey: ["shifts"] });
      toast.success(t("pos.stuckShiftClosed"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });



  // Cashback levels set by the owner: each level's spend target pays its reward into the wallet.
  const cashback = useQuery({
    queryKey: ["cashback-settings"],
    enabled: canUse,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("cashback_settings");
      if (error) throw error;
      return parseCashbackConfig(data);
    },
  });
  const cashbackOn = Boolean(cashback.data?.enabled && cashback.data.tiers.length > 0);
  // Which level the linked customer is on (the lookup row only carries the spend).
  const customerLevel = useQuery({
    queryKey: ["pos-customer-cashback", customer?.id],
    enabled: cashbackOn && Boolean(customer?.id),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("customer_cashback", { _customer_id: customer!.id });
      if (error) throw error;
      const v = (data ?? {}) as Record<string, unknown>;
      return Math.max(Number(v["level"] ?? 1) - 1, 0);
    },
  });

  // Super-admin editable footer message printed under both receipt copies.
  const receiptSettings = useQuery({
    queryKey: ["receipt-footer-settings"],
    enabled: canUse,
    queryFn: async () => {
      try {
        const { data, error } = await supabase
          .from("app_settings")
          .select("value")
          .eq("key", "receipt_footer_message")
          .maybeSingle();
        if (error) return "";
        const value = data?.value;
        if (typeof value === "string") return value;
        if (value && typeof value === "object") {
          return String((value as Record<string, unknown>)["message"] ?? "");
        }
        return "";
      } catch {
        return "";
      }
    },
  });

  // Split payments. A "cashback" line pays from the linked customer's wallet.
  const walletBalance = Number(customer?.wallet_balance ?? 0);
  // Visit stamps were retired on 2026-10-20 (cashback is the loyalty rule); their data is kept.
  const visitRewardsOn = false;
  const visitsNeeded = 10;
  const visitStamps = Number(customer?.points_balance ?? 0);
  const rewardEligible = visitRewardsOn && Boolean(customer) && visitStamps >= visitsNeeded && partnerMode !== "tab";
  const paySummary = summarizePayments(payRows, totals.total, walletBalance);
  const paidSum = paySummary.paid;
  const cashbackUsed = paySummary.cashbackUsed;
  const payRemaining = paySummary.remaining;
  const payBalanced = paySummary.balanced && !paySummary.hasNegative;
  const cashbackOver = paySummary.cashbackOver;
  // Cashback the customer will earn with this bill (wallet money doesn't count toward the target).
  const cashbackPreview = (() => {
    if (!cashbackOn || !cashback.data) return { earn: 0, left: 0 };
    const tiers = cashback.data.tiers;
    const after = accrueCashback(
      tiers,
      Number(customer?.cashback_progress ?? 0),
      customerLevel.data ?? 0,
      Math.max(totals.total - cashbackUsed, 0),
    );
    return { earn: after.earned, left: nextTier(tiers, after.progress, after.level)?.left ?? 0 };
  })();

  // One tap: pay as much of the bill as the wallet covers; the other lines absorb the rest.
  const applyCashback = () => {
    const use = Math.round(Math.min(walletBalance, totals.total) * 100) / 100;
    if (use <= 0) return;
    setPayRows((prev) => {
      const others = prev.filter((row) => row.methodKey !== "cashback");
      const rest = Math.round((totals.total - use) * 100) / 100;
      const base = others.length ? others : [newPayRow("cash")];
      const adjusted = base.map((row, index) => (index === 0 ? { ...row, amount: rest > 0 ? String(rest) : "" } : { ...row, amount: "" }));
      return [newPayRow("cashback", String(use)), ...(rest > 0 ? adjusted : [])];
    });
  };

  // Live suggestions while the cashier types a name / phone / customer ID.

  // Phone-first lookup: 3 digits in the phone box (or 2 characters in the search box)
  // list saved customers. Any seller sees it; the server returns till fields only.
  const searchTerm = customerLookupTerm(customerQuery, customerPhone);
  const customerSearch = usePosCustomerLookup(searchTerm, {
    enabled: canUse && !customer,
    canBrowseCustomers: can("loyalty.view"),
  });

  const pickCustomer = (row: {
    id: string;
    code: string;
    name: string;
    phone: string | null;
    wallet_balance: number;
    cashback_progress: number;
    points_balance?: number | null;
  }) => {
    setCustomer(row);
    setRewardLineKey(null);
    setCustomerName(row.name);
    setCustomerPhone(row.phone ?? "");
    setCustomerQuery("");
    setCustomerToolsOpen(false);
    toast.success(`${row.name} · ${lang === "ar" ? "رصيد الكاش باك" : "Cashback"}: ${formatMoney(Number(row.wallet_balance), currency, lang)}`);
  };

  const saveCustomer = useMutation({
    mutationFn: async () => {
      const { data: newId, error } = await supabase.rpc("upsert_customer", {
        _name: customerName.trim() || customerQuery.trim(),
        _phone: customerPhone.trim() || customerQuery.trim(),
      });
      if (error) throw error;
      const { data, error: readError } = await supabase
        .from("customers")
        .select("id, code, name, phone, wallet_balance, cashback_progress, points_balance")
        .eq("id", newId as unknown as string)
        .maybeSingle();
      if (readError) throw readError;
      return data;
    },
    onSuccess: (row) => {
      if (!row) return;
      setCustomer(row);
      setCustomerName(row.name);
      setCustomerPhone(row.phone ?? "");
      setCustomerQuery("");
      setCustomerToolsOpen(false);
      toast.success(`${row.name} · ${row.code}`);
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Active partners for "on the house account" orders; the RPC hides financials.
  const partners = useQuery({
    queryKey: ["pos-partners"],
    enabled: Boolean(me),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("pos_partners");
      if (error) throw error;
      return (data ?? []) as Array<{ id: string; name: string; customer_id: string | null }>;
    },
  });
  // Picking a partner from the cart dropdown auto-switches the order to their tab.
  const onPartnerTab = partnerMode === "tab" || Boolean(partnerId);

  const submitOrder = useMutation({
    mutationFn: async () => {
      if (!onPartnerTab) {
        if (payRows.length === 0) throw new Error("Select a payment method");
        if (!payBalanced) throw new Error("Payments must match the order total");
        if (cashbackOver) throw new Error(lang === "ar" ? "الكاش باك المستخدم أكبر من رصيد العميل" : "Cashback used exceeds the customer's wallet");
      }
      const payments = toServerPayments(payRows, (key) => methodByKey(key)?.id ?? null);
      const { data, error } = await supabase.rpc("create_pos_order", {
        _branch_id: currentBranchId!,
        _items: cart.map((line) => ({
          custom: Boolean(line.custom),
          product_id: line.custom ? null : line.product_id,
          size_id: line.size_id,
          product_name: line.product_name,
          size_name: line.size_name,
          unit_price: line.unit_price,
          quantity: line.quantity,
          is_taxable: line.is_taxable,
          offer_id: line.offer_id ?? null,
          bundle_key: line.bundle_key ?? null,
          modifiers: line.modifiers,
          ...(line.key === rewardLineKey ? { free_reward: true } : {}),
        })),
        _payments: onPartnerTab ? [] : payments,
        _order_type: orderType,
        _discount_amount: totals.manualDiscount,
        ...(orderNote.trim() ? { _notes: orderNote.trim().slice(0, 500) } : {}),
        ...(discountReason ? { _discount_reason: discountReason } : {}),
        ...(customerName ? { _customer_name: customerName } : {}),
        ...(customerPhone ? { _customer_phone: customerPhone } : {}),
        ...(customer ? { _customer_id: customer.id } : {}),
        ...(partnerId ? { _partner_id: partnerId } : {}),
        _on_partner_tab: onPartnerTab,
      });
      if (error) throw error;
      const created = data?.[0];
      return created ? { id: created.out_id, number: created.out_number } : null;
    },
    onSuccess: async (createdOrder) => {
      setPayOpen(false);
      const orderNumber = createdOrder?.number ?? null;
      setLastOrder(orderNumber ? invoiceSequence(orderNumber) : null);
      await queryClient.invalidateQueries({ queryKey: ["orders"] });
      await queryClient.invalidateQueries({ queryKey: ["loyalty-customers"] });
      toast.success(
        `${t("pos.orderDone")} ${orderNumber ? `#${invoiceSequence(orderNumber)}` : ""}`,
      );
      // Partner tab orders are unpacked server-side at full menu prices.
      if (onPartnerTab && cart.some((line) => line.bundle_key)) {
        toast.info(t("pos.partnerTabBundleNotice"));
      }

      // Fetch the saved order and print customer receipt + kitchen ticket.
      if (orderNumber && createdOrder) {
        const { data: orderRows } = await supabase
          .from("orders")
          .select(
            "id, order_number, order_type, created_at, subtotal, discount_amount, tax_amount, total, customer_name, customer_phone, notes, order_items(id, product_name, size_name, unit_price, quantity, line_total, status, notes, order_item_modifiers(name)), order_payments(method_key, payment_methods(key, name, kind), amount, reference)",
          )
          .eq("id", createdOrder.id)
          .single();
        if (orderRows) {
          const { data: walletRows } = await supabase
            .from("customer_wallet_transactions")
            .select("kind, amount, balance_after, created_at")
            .eq("order_id", orderRows.id)
            .order("created_at", { ascending: true });
          const order = orderRows as unknown as {
            id: string;
            order_number: string;
            order_type: string;
            created_at: string;
            subtotal: number;
            discount_amount: number;
            tax_amount: number;
            total: number;
            customer_name: string | null;
            customer_phone: string | null;
            notes: string | null;
            order_items: Array<{
              id: string;
              product_name: string;
              size_name: string | null;
              unit_price: number;
              quantity: number;
              line_total: number;
              status: string;
              notes: string | null;
              order_item_modifiers: Array<{ name: string }>;
            }>;
            order_payments: Array<{
              method_key: string;
              payment_methods: { key: string; name: string; kind: string } | null;
              amount: number;
              reference: string | null;
            }>;
          };
          const currentBranch =
            me?.branches.find((b) => b.id === currentBranchId) ?? me?.branches[0];
          const rawCashier =
            me?.profile.display_name ??
            `${me?.profile.first_name ?? ""} ${me?.profile.last_name ?? ""}`.trim();
          const cashierName = rawCashier || null;
          const walletMoves = walletRows ?? [];
          const cashbackEarned = walletMoves.filter((w) => w.kind === "earn").reduce((sum, w) => sum + Number(w.amount), 0);
          const lastMove = walletMoves.at(-1);
          const changeAmount = change;

          const receiptData = {
            companyName: me?.company?.name ?? t("app.name"),
            branchName: currentBranch?.name ?? null,
            orderNumber: order.order_number,
            createdAt: order.created_at,
            orderType:
              ({ dine_in: "Dine-in", takeaway: "Takeaway", delivery: "Delivery" } as Record<
                string,
                string
              >)[order.order_type] ?? order.order_type,
            cashier: cashierName,
            lines: order.order_items.map((it) => ({
              product_name: it.product_name,
              size_name: it.size_name,
              unit_price: it.unit_price,
              quantity: it.quantity,
              line_total: it.line_total,
              status: it.status,
              modifiers: it.order_item_modifiers,
              notes: it.notes,
            })),
            notes: order.notes,
            subtotal: order.subtotal,
            discount: order.discount_amount,
            total: order.total,
            payments: order.order_payments.map((p) => ({
              method_key: p.method_key === "cashback" ? "cashback" : (p.payment_methods?.key ?? p.method_key),
              amount: p.amount,
            })),
            customerName: order.customer_name,
            customerPhone: order.customer_phone,
            cashbackUsed: cashbackUsed,
            cashbackEarned,
            walletBalance: lastMove ? Number(lastMove.balance_after) : customer ? walletBalance : null,
            footerMessage: receiptSettings.data || null,
            change: changeAmount,
            currency,
            lang,
            labels: {
              order: t("receipt.order"),
              subtotal: t("receipt.subtotal"),
              discount: t("receipt.discount"),
              total: t("receipt.total"),
              refunded: t("receipt.refunded"),
              customer: t("receipt.customer"),
              pointsEarned: t("receipt.pointsEarned"),
              pointsBalance: t("receipt.pointsBalance"),
              thanks: t("receipt.thanks"),
              voided: t("receipt.voided"),
            },
          };
          printReceipt(receiptData);

          // Combos need a barista ticket that itemizes every drink inside them.
          if (cart.some((line) => line.bundle_key)) {
            printBaristaTicket({
              companyName: me?.company?.name ?? t("app.name"),
              branchName: currentBranch?.name ?? null,
              orderNumber: order.order_number,
              createdAt: order.created_at,
              orderType: receiptData.orderType,
              customerName: order.customer_name,
              notes: order.notes,
              lines: cart.map((line) => ({
                product_name: line.product_name,
                size_name: line.size_name,
                quantity: line.quantity,
                modifiers: line.modifiers.map((m) => ({ name: m.name })),
                notes: null,
                bundle_key: line.bundle_key ?? null,
                bundle_title: line.offer_title ?? null,
              })),
              lang,
              labels: {
                order: t("receipt.order"),
                customer: t("receipt.customer"),
                kitchenHint: t("receipt.kitchenHint"),
              },
            });
          }
        }
      }
      resetOrder();
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Warns about missing ingredients before the cashier takes the money.

  const startPayment = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("check_order_stock", {
        _branch_id: currentBranchId!,
        _items: cart.filter((line) => !line.custom).map((line) => ({
          product_id: line.product_id,
          size_id: line.size_id,
          quantity: line.quantity,
          modifiers: line.modifiers,
        })),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      if (partnerId) setPartnerMode("tab");
      setPayRows([newPayRow("cash", totals.total.toFixed(2))]);
      setCashReceived(totals.total.toFixed(2));
      setPayOpen(true);
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Emergency stock bypass: logs to the audit trail and lets this cashier sell for 8 hours despite short stock.
  const emergencyBypass = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("begin_stock_override", {
        _branch_id: currentBranchId!,
        _items: cart.filter((line) => !line.custom).map((line) => ({ product_id: line.product_id, quantity: line.quantity })) as never,
        _reason: "طوارئ / تجاوز المخزون المؤقت",
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.warning(lang === "ar" ? "تم تفعيل التجاوز الطارئ لمدة 8 ساعات وتسجيله في سجل التدقيق" : "Emergency bypass active for 8 hours and logged");
      setPayRows([newPayRow("cash", totals.total.toFixed(2))]);
      setCashReceived(totals.total.toFixed(2));
      setPayOpen(true);
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const barLow = useBarLowStock(currentBranchId);
  if (!canUse) return <NoPermission message={t("common.noAccess")} />;

  return (
    <div>
      <PageHeader
        title={t("pos.title")}
        description={t("pos.subtitle")}
        action={
          shift.data ? (
            <div className="flex flex-wrap items-center gap-2">
              <span className="flex flex-wrap items-center gap-2 rounded-full border border-primary/30 bg-primary/10 px-3 py-1.5 text-xs font-medium transition-all duration-200">
                <span className="inline-flex size-2 rounded-full bg-primary" />
                <span>{me?.profile.display_name || me?.profile.first_name}</span>
                <span className="text-muted-foreground">
                  {lang === "ar" ? "بدأت" : "since"}{" "}
                  {new Date(shift.data.opened_at).toLocaleTimeString(
                    lang === "ar" ? "ar-EG" : "en-US",
                    { hour: "2-digit", minute: "2-digit" },
                  )}
                </span>
                <Badge variant="secondary">
                  {t("pos.shiftOpen")} · {formatMoney(shift.data.opening_cash, currency, lang)}
                </Badge>
                <InfoTip title="الوردية">الوردية هي فترة شغلك على الكاشير. بتفتحها في الأول وتكتب الفلوس اللي في الدرج، وكل البيع بيتسجل عليها. وفي الآخر تقفلها وتعدّ الدرج، والسيستم يقولك لو فيه عجز أو زيادة.</InfoTip>
              </span>
              <Button
                variant="destructive"
                disabled={cart.length === 0 || emergencyBypass.isPending}
                onClick={() => emergencyBypass.mutate()}
              >
                {lang === "ar" ? "طوارئ / تجاوز المخزون المؤقت" : "Emergency stock bypass"}
              </Button>
              <InfoTip title="تجاوز المخزون المؤقت">زرار تستخدمه للضرورة القصوى بس، عشان تخلّي السيستم يكمّل البيعة حتى لو رصيد البار خلصان أو بالسالب مؤقتاً. بيفضل شغال 8 ساعات وبيتسجل باسمك، والخصم من المخزون بيكمل عادي — فلازم تظبط الرصيد بعدها بجرد أو شراء.</InfoTip>
              <Button variant="outline" onClick={() => setRosterOpen(true)}>
                <Users className="size-4" />
                {lang === "ar" ? "تعديل طاقم الوردية" : "Edit shift staff"}
              </Button>
              {(can("expenses.create") || isSuperAdmin) && (
                <Button variant="outline" onClick={() => setExpenseOpen(true)}>
                  <Wallet className="size-4" />
                  {lang === "ar" ? "مصروف من الدرج" : "Drawer expense"}
                </Button>
              )}
              {can("shifts.close") && (
                <Button
                  variant="outline"
                  className="transition-all duration-200"
                  onClick={() => setCloseOpen(true)}
                >
                  {t("pos.closeShift")}
                </Button>
              )}
            </div>
          ) : (
            can("shifts.open") && (
              <Button
                className="transition-all duration-200"
                onClick={() => setOpenCashOpen(true)}
                disabled={!currentBranchId}
              >
                {t("pos.openShift")}
              </Button>
            )
          )
        }
      />
      <BarLowStockAlert items={barLow.items} showLink={can("inventory.view") || isSuperAdmin} />


      {shift.data && currentBranchId && (
        <PosShiftKpis branchId={currentBranchId} shiftId={shift.data.id} currency={currency} lang={lang === "ar" ? "ar" : "en"} />
      )}

      {/* Shift gate: one clean centred card until a shift is open. */}
      {!shift.data && !shift.isLoading && (
        <div className="flex justify-center py-6 sm:py-10">
          <div className="animate-scale-in w-full max-w-md rounded-2xl border bg-card p-6 shadow-elegant sm:p-8">
            <div className="mb-6 text-center">
              <div className="mx-auto mb-3 grid size-14 place-items-center rounded-2xl bg-gradient-brand text-primary-foreground shadow-glow">
                <Wallet className="size-6" />
              </div>
              <h2 className="text-xl font-bold">{lang === "ar" ? "افتتاح وردية جديدة" : "Open a new shift"}</h2>
              <p className="mt-1 text-sm text-muted-foreground">{t("pos.needShift")}</p>
            </div>
            {stuckShift.data && (
              <div className="mb-5 space-y-2 rounded-xl bg-destructive/10 p-4">
                <p className="text-sm font-medium text-destructive">{t("pos.stuckShiftTitle")}</p>
                <p className="text-xs text-muted-foreground">
                  {t("pos.stuckShiftHint")
                    .replace("{name}", stuckShift.data.user_profiles?.display_name || stuckShift.data.user_profiles?.first_name || "—")
                    .replace("{time}", new Date(stuckShift.data.opened_at).toLocaleString(lang === "ar" ? "ar-EG" : "en-US"))}
                </p>
                <Button
                  variant="destructive"
                  className="h-11 w-full"
                  disabled={!can("shifts.close") || forceCloseShift.isPending}
                  onClick={() => setForceCloseOpen(true)}
                >
                  {t("pos.stuckShiftClose")}
                </Button>
              </div>
            )}
            <div className="space-y-5">
              <div className="space-y-2">
                <Label htmlFor="gate-opening">{t("pos.openingCash")}</Label>
                <Input
                  id="gate-opening"
                  inputMode="decimal"
                  className="h-14 text-center text-2xl font-bold tabular-nums"
                  value={openingCash}
                  onChange={(event) => setOpeningCash(event.target.value)}
                />
              </div>
              <div className="space-y-2">
                <Label>{lang === "ar" ? "طاقم الوردية" : "Shift crew"}</Label>
                <StaffPicker value={rosterIds} onChange={setRosterIds} lang={lang === "ar" ? "ar" : "en"} />
              </div>
              <Button
                size="lg"
                className="h-12 w-full text-base"
                disabled={!can("shifts.open") || !currentBranchId || openShift.isPending || Boolean(stuckShift.data)}
                onClick={() => openShift.mutate()}
              >
                {openShift.isPending ? (lang === "ar" ? "جارٍ الفتح..." : "Opening...") : t("pos.openShift")}
              </Button>
            </div>
          </div>
        </div>
      )}

      <AlertDialog open={forceCloseOpen} onOpenChange={setForceCloseOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("pos.stuckShiftClose")}</AlertDialogTitle>
            <AlertDialogDescription>{t("pos.stuckShiftConfirm")}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => forceCloseShift.mutate()}
              disabled={forceCloseShift.isPending}
            >
              {t("common.confirm")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>


      {shift.data && (
        <div className="grid gap-4 lg:grid-cols-[1fr_360px]">
          <div>
            <div className="sticky top-0 z-20 mb-3 rounded-2xl border border-border bg-card p-2 shadow-sm">
              <div className="relative">
                <Search className="pointer-events-none absolute start-3 top-1/2 size-5 -translate-y-1/2 text-muted-foreground" />
                <Input
                  autoFocus
                  type="search"
                  value={productSearch}
                  onChange={(e) => setProductSearch(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && productSearch.trim() && visibleProducts[0]) {
                      const first = visibleProducts.find((p) => p.is_available && hasRecipe(p.id));
                      if (first) {
                        pickProduct(first);
                        setProductSearch("");
                      }
                    }
                  }}
                  placeholder={lang === "ar" ? "ابحث عن صنف بالاسم أو الكود…" : "Search products by name or code…"}
                  aria-label={lang === "ar" ? "بحث الأصناف" : "Search products"}
                  className="h-12 ps-10 pe-10 text-base"
                />
                {productSearch && (
                  <button
                    type="button"
                    aria-label="clear"
                    onClick={() => setProductSearch("")}
                    className="absolute end-2 top-1/2 grid size-8 -translate-y-1/2 place-items-center rounded-md text-muted-foreground hover:bg-muted"
                  >
                    <X className="size-4" />
                  </button>
                )}
              </div>
            </div>
            <div className="mb-3 flex flex-wrap gap-2">
              <Button
                className="min-h-11"
                variant={categoryId === "all" ? "default" : "outline"}
                onClick={() => setCategoryId("all")}
              >
                {t("pos.allCategories")}
              </Button>
              {(categories.data ?? []).map((c) => (
                <Button
                  key={c.id}
                  className="min-h-11"
                  variant={categoryId === c.id ? "default" : "outline"}
                  onClick={() => setCategoryId(c.id)}
                >
                  {label(c.name, c.name_ar)}
                </Button>
              ))}
              {bundleOffers.length > 0 && (
                <Button
                  size="sm"
                  variant={categoryId === "offers" ? "default" : "outline"}
                  onClick={() => setCategoryId("offers")}
                >
                  🔥 {t("pos.offersTab")}
                </Button>
              )}
            </div>

            {categoryId === "offers" ? (
              <div className="stagger grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
                {bundleOffers.map((offer) => {
                  const src = offer.image_path
                    ? (bundleImageUrls.data?.get(offer.image_path) ?? null)
                    : null;
                  const saving = Math.max(0, offer.base_price - offer.offer_price);
                  return (
                    <div key={offer.id} className="card-frame">
                      <div className="card-frame-inner overflow-hidden">
                        {src ? (
                          <button
                            type="button"
                            onClick={() => setBundleLightbox({ src, alt: offer.title })}
                            className="block w-full"
                          >
                            <img
                              src={src}
                              alt={offer.title}
                              loading="lazy"
                              className="aspect-[4/3] w-full object-cover"
                            />
                          </button>
                        ) : (
                          <div className="grid aspect-[4/3] w-full place-items-center bg-gradient-brand text-lg font-bold text-primary-foreground">
                            {offer.title.slice(0, 2)}
                          </div>
                        )}
                        <div className="space-y-2 p-3">
                          <p className="font-semibold text-foreground">{offer.title}</p>
                          <ul className="space-y-0.5 text-xs text-muted-foreground">
                            {offer.items.map((it) => {
                              const p = (products.data ?? []).find((row) => row.id === it.product_id);
                              return (
                                <li key={`${offer.id}-${it.product_id}`}>
                                  {it.quantity}× {p ? label(p.name, p.name_ar) : "—"}
                                </li>
                              );
                            })}
                          </ul>
                          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                            <span className="rounded-full bg-accent px-2 py-0.5 text-sm font-bold tabular-nums text-accent-foreground">
                              {formatMoney(offer.offer_price, currency, lang)}
                            </span>
                            {offer.base_price > offer.offer_price && (
                              <span className="text-xs text-muted-foreground line-through tabular-nums">
                                {formatMoney(offer.base_price, currency, lang)}
                              </span>
                            )}
                            {saving > 0 && (
                              <span className="text-xs font-semibold text-primary tabular-nums">
                                -{formatMoney(saving, currency, lang)}
                              </span>
                            )}
                          </div>
                          <Button className="min-h-11 w-full" onClick={() => addBundle(offer)}>
                            {t("pos.addToCart")}
                          </Button>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : visibleProducts.length === 0 ? (
              <EmptyState message={t("menu.emptyProducts")} />
            ) : (
              <div className="stagger grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
                {visibleProducts.map((product) => {
                  const sizes = product.product_sizes.filter((s) => s.is_active);
                  const groups = activeGroups(product);
                  const ingredients = recipes.data?.get(product.id) ?? [];
                  const image = imageOf(product.image_url);
                  const recipeReady = hasRecipe(product.id);
                  return (
                    <div key={product.id} className="card-frame group relative">
                      <SoldOutToggle
                        productId={product.id}
                        available={product.is_available}
                        lang={lang === "ar" ? "ar" : "en"}
                      />
                      <LowStockCardBadge items={barLow.byProduct.get(product.id)} />

                      <button
                        type="button"
                        disabled={!product.is_available || !recipeReady}
                        onClick={() => pickProduct(product)}
                        className="card-frame-inner relative flex min-h-44 w-full flex-col overflow-hidden text-start disabled:cursor-not-allowed disabled:opacity-50"
                      >
                        <div className="relative aspect-[4/3] w-full overflow-hidden bg-muted">
                          {image ? (
                            <img
                              src={image}
                              alt={label(product.name, product.name_ar)}
                              loading="lazy"
                              className="size-full object-cover transition-transform duration-500 group-hover:scale-105"
                            />
                          ) : (
                            <div className="grid size-full place-items-center bg-gradient-brand text-lg font-bold text-primary-foreground">
                              {label(product.name, product.name_ar).slice(0, 2)}
                            </div>
                          )}
                          {!product.is_available && (
                            <Badge variant="destructive" className="absolute end-2 top-2 shadow-sm">
                              {t("menu.unavailable")}
                            </Badge>
                          )}
                          {product.is_available && !recipeReady && (
                            <Badge variant="destructive" className="absolute end-2 top-2 shadow-sm">
                              {lang === "ar" ? "بدون وصفة" : "No recipe"}
                            </Badge>
                          )}
                          <div className="product-scrim @container pointer-events-none absolute inset-0 flex -translate-x-full flex-col items-center justify-start gap-[2cqh] overflow-hidden p-[4cqw] text-center opacity-0 transition-all duration-500 ease-out group-hover:translate-x-0 group-hover:opacity-100 group-focus-within:translate-x-0 group-focus-within:opacity-100 rtl:translate-x-full rtl:group-hover:translate-x-0 rtl:group-focus-within:translate-x-0">
                            <div className="w-full">
                              <p className="text-[clamp(0.85rem,5.5cqw,1.35rem)] font-extrabold leading-tight tracking-wide text-primary">
                                {t("pos.composition")}
                              </p>
                              <div className="mx-auto mt-[1.5cqh] h-px w-full bg-white/80" />
                            </div>
                            {sizes.length === 0 &&
                            groups.length === 0 &&
                            ingredients.length === 0 ? (
                              <p className="product-scrim-muted text-[clamp(0.7rem,4cqw,1rem)]">
                                {t("pos.noDetails")}
                              </p>
                            ) : (
                              <>
                                {sizes.length > 0 && (
                                  <div>
                                    <p className="text-[clamp(0.62rem,3.4cqw,0.9rem)] font-bold uppercase tracking-wide text-accent">
                                      {t("pos.sizesAvailable")}
                                    </p>
                                    <p className="text-[clamp(0.68rem,3.8cqw,1rem)] font-semibold leading-snug">
                                      {sizes
                                        .map(
                                          (s) =>
                                            `${label(s.name, s.name_ar)}${
                                              Number(s.price_delta)
                                                ? ` (+${Number(s.price_delta)})`
                                                : ""
                                            }`,
                                        )
                                        .join(" · ")}
                                    </p>
                                  </div>
                                )}
                                {groups.length > 0 && (
                                  <div>
                                    <p className="text-[clamp(0.62rem,3.4cqw,0.9rem)] font-bold uppercase tracking-wide text-accent">
                                      {t("pos.addOns")}
                                    </p>
                                    <p className="text-[clamp(0.68rem,3.8cqw,1rem)] font-semibold leading-snug">
                                      {groups
                                        .flatMap((g) =>
                                          g.modifier_options
                                            .filter((o) => o.is_active)
                                            .map((o) => label(o.name, o.name_ar)),
                                        )
                                        .join(" · ")}
                                    </p>
                                  </div>
                                )}
                                {ingredients.length > 0 && (
                                  <div>
                                    <p className="text-[clamp(0.62rem,3.4cqw,0.9rem)] font-bold uppercase tracking-wide text-accent">
                                      {t("pos.ingredients")}
                                    </p>
                                    <ul className="space-y-0.5 text-[clamp(0.68rem,3.8cqw,1rem)] font-semibold leading-snug">
                                      {ingredients.map((line) => (
                                        <li key={line}>{line}</li>
                                      ))}
                                    </ul>
                                  </div>
                                )}
                              </>
                            )}
                          </div>
                        </div>
                        <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2 p-3">
                          <p className="truncate font-semibold text-foreground">
                            {label(product.name, product.name_ar)}
                          </p>
                          {(() => {
                            const base = Number(product.base_price);
                            const offer = offerFor(product.id);
                            return offer && offer.price < base ? (
                              <span className="flex shrink-0 items-center gap-1.5">
                                <span className="text-xs text-muted-foreground line-through tabular-nums">
                                  {formatMoney(base, currency, lang)}
                                </span>
                                <span className="rounded-full bg-accent px-2 py-0.5 text-sm font-bold tabular-nums text-accent-foreground">
                                  {formatMoney(offer.price, currency, lang)}
                                </span>
                              </span>
                            ) : (
                              <span className="shrink-0 rounded-full bg-primary/10 px-2 py-0.5 text-sm font-bold tabular-nums text-primary">
                                {formatMoney(base, currency, lang)}
                              </span>
                            );
                          })()}
                        </div>
                      </button>
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          <Card className="flex h-[calc(100vh-4rem)] flex-col overflow-hidden border-r bg-card lg:sticky lg:top-4 lg:h-[calc(100vh-11rem)]">
            <CardHeader className="flex h-11 shrink-0 flex-row items-center justify-between gap-2 space-y-0 border-b px-3 py-1.5">
              <CardTitle className="flex min-w-0 items-center gap-2 text-sm">
                <ShoppingCart className="size-4 shrink-0 text-primary" />
                <span className="truncate">{t("pos.cart")}</span>
              </CardTitle>
              <Select value={orderType} onValueChange={(v) => setOrderType(v as typeof orderType)}>
                <SelectTrigger className="h-8 w-32 text-xs">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="dine_in">{t("pos.dineIn")}</SelectItem>
                  <SelectItem value="takeaway">{t("pos.takeaway")}</SelectItem>
                  <SelectItem value="delivery">{t("pos.delivery")}</SelectItem>
                </SelectContent>
              </Select>
            </CardHeader>
            <CardContent className="flex min-h-0 flex-1 flex-col p-0">
              <div className="shrink-0 border-b px-2 py-1.5">
                <Label className="mb-1 block text-[10px] text-muted-foreground">
                  {lang === "ar" ? "اسم الزبون (إلزامي)" : "Customer name (required)"}
                </Label>
                {!customerToolsOpen && (customer || customerName.trim()) ? (
                  <div className="flex h-8 items-center justify-between gap-1 rounded-md bg-secondary/60 px-2 text-xs">
                    <span className="min-w-0 truncate font-medium">
                      {lang === "ar" ? "العميل" : "Customer"}: {customer?.name || customerName}
                      {customer
                        ? ` (${lang === "ar" ? "كاش باك" : "Cashback"}: ${formatMoney(walletBalance, currency, lang)}${
                            visitRewardsOn ? ` · ${lang === "ar" ? "زيارات" : "Visits"}: ${visitStamps}/${visitsNeeded}` : ""
                          })`
                        : ""}
                    </span>
                    <Button
                      size="icon"
                      variant="ghost"
                      className="size-7 shrink-0"
                      onClick={() => {
                        setCustomer(null);
                        setRewardLineKey(null);
                        setCustomerName("");
                        setCustomerPhone("");
                      }}
                      aria-label={t("pos.clearCustomer")}
                    >
                      <X className="size-3.5" />
                    </Button>
                  </div>
                ) : (
                  <Popover open={customerToolsOpen} onOpenChange={setCustomerToolsOpen}>
                    <PopoverTrigger asChild>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-8 w-full justify-start text-primary"
                      >
                        <UserPlus className="size-4" />
                        {lang === "ar" ? "+ إدخال اسم الزبون" : "+ Enter customer name"}
                      </Button>
                    </PopoverTrigger>
                    <PopoverContent
                      align="end"
                      side="bottom"
                      sideOffset={6}
                      avoidCollisions={false}
                      className="w-80 space-y-3 p-3"
                    >
                      <div className="space-y-2">
                        <Label className="text-xs">
                          {lang === "ar" ? "اسم الزبون (سريع)" : "Customer name (quick)"}
                        </Label>
                        <Input
                          className="h-8"
                          placeholder={t("pos.customerName")}
                          value={customerName}
                          onChange={(e) => setCustomerName(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === "Enter" && customerName.trim())
                              setCustomerToolsOpen(false);
                          }}
                        />
                        <Input
                          className="h-8"
                          inputMode="tel"
                          placeholder={t("common.phone")}
                          value={customerPhone}
                          onChange={(e) => setCustomerPhone(e.target.value)}
                          onKeyDown={(e) => {
                            const first = customerSearch.data?.[0];
                            if (e.key === "Enter" && first && !customerQuery.trim()) pickCustomer(first);
                          }}
                        />
                        {!customerQuery.trim() && searchTerm && (
                          <CustomerSuggestionList
                            rows={customerSearch.data ?? []}
                            loading={customerSearch.isFetching}
                            lang={lang}
                            currency={currency}
                            onPick={pickCustomer}
                          />
                        )}
                        <Button
                          size="sm"
                          className="w-full"
                          disabled={!customerName.trim()}
                          onClick={() => setCustomerToolsOpen(false)}
                        >
                          {lang === "ar" ? "استخدام الاسم للفاتورة" : "Use name on invoice"}
                        </Button>
                      </div>
                      {can("loyalty.view") && <div className="border-t pt-2" />}
                      {can("loyalty.view") && (
                        <>
                          <Label className="text-xs">
                            {lang === "ar"
                              ? "أو ابحث في العملاء المسجلين"
                              : "Or search saved customers"}
                          </Label>
                          <div className="flex gap-2">
                            <Input
                              className="h-8 min-w-0 flex-1"
                              placeholder={t("pos.customerSearch")}
                              value={customerQuery}
                              onChange={(e) => setCustomerQuery(e.target.value)}
                              onKeyDown={(e) => {
                                const first = customerSearch.data?.[0];
                                if (e.key === "Enter" && first) pickCustomer(first);
                              }}
                            />
                            <Button
                              size="sm"
                              variant="outline"
                              disabled={
                                saveCustomer.isPending ||
                                (customerQuery.trim().length < 6 && !customerName.trim())
                              }
                              onClick={() => saveCustomer.mutate()}
                            >
                              {t("pos.newCustomer")}
                            </Button>
                          </div>

                          {customerQuery.trim().length >= 2 && (
                            <CustomerSuggestionList
                              rows={customerSearch.data ?? []}
                              loading={customerSearch.isFetching}
                              lang={lang}
                              currency={currency}
                              onPick={pickCustomer}
                              emptyText={t("pos.customerNotFound")}
                            />
                          )}
                        </>
                      )}
                    </PopoverContent>
                  </Popover>
                )}
                {(partners.data ?? []).length > 0 && (
                  <div className="mt-1.5 space-y-1">
                    <Label className="block text-[10px] text-muted-foreground">
                      {lang === "ar"
                        ? "طلب شريك؟ (يُخصم من صافي ربحه)"
                        : "Partner order? (deducted from their profit)"}
                    </Label>
                    <Select
                      value={partnerId || "none"}
                      onValueChange={(v) => setPartnerId(v === "none" ? "" : v)}
                    >
                      <SelectTrigger
                        className={`h-8 text-xs ${partnerId ? "border-accent bg-accent/10 font-bold" : ""}`}
                      >
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="none">
                          {lang === "ar"
                            ? "زبون عادي (دفع نقدي / فيزا...)"
                            : "Regular customer (cash / card...)"}
                        </SelectItem>
                        {(partners.data ?? []).map((partner) => (
                          <SelectItem key={partner.id} value={partner.id}>
                            {partner.name}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                    {partnerId && (
                      <p className="text-[10px] font-medium text-accent-foreground">
                        {lang === "ar"
                          ? "الفاتورة ستُرحَّل على حساب الشريك وتُخصم من أرباحه في التوزيع القادم"
                          : "Invoice charged to the partner and deducted from their next profit share"}
                      </p>
                    )}
                  </div>
                )}
              </div>
              <div className="scrollbar-thin min-h-0 flex-1 space-y-1.5 overflow-y-auto p-2">
                {cart.length === 0 ? (
                  <p className="py-6 text-center text-sm text-muted-foreground">
                    {t("pos.emptyCart")}
                  </p>
                ) : (
                  <div className="space-y-1.5">
                    {cart.map((line) => (
                      <div
                        key={line.key}
                        className="grid min-h-10 grid-cols-[minmax(0,1fr)_auto_auto_auto] items-center gap-1 rounded-md border border-border px-1.5 py-1"
                      >
                        <div
                          className="min-w-0"
                          title={`${line.product_name}${line.size_name ? ` · ${line.size_name}` : ""}${line.modifiers.length ? ` — ${line.modifiers.map((m) => m.name).join(", ")}` : ""}`}
                        >
                          <p className="truncate text-xs font-bold text-foreground">
                            {line.product_name}
                            {line.size_name ? ` · ${line.size_name}` : ""}
                          </p>
                          {line.modifiers.length > 0 && (
                            <p className="truncate text-[10px] leading-none text-muted-foreground">
                              {line.modifiers.map((m) => m.name).join("، ")}
                            </p>
                          )}
                          {!line.bundle_key && (
                            <button
                              type="button"
                              onClick={() => setExtrasLineKey(line.key)}
                              className="mt-0.5 text-[10px] font-bold text-primary hover:underline"
                            >
                              + {lang === "ar" ? "إضافات" : "Extras"}
                            </button>
                          )}
                          {rewardEligible && !line.bundle_key && !line.custom && (
                            <button
                              type="button"
                              onClick={() => setRewardLineKey((k) => (k === line.key ? null : line.key))}
                              className={`ms-2 mt-0.5 rounded px-1 text-[10px] font-bold ${
                                rewardLineKey === line.key
                                  ? "bg-success/15 text-success"
                                  : "text-success hover:underline"
                              }`}
                            >
                              {rewardLineKey === line.key
                                ? lang === "ar" ? "مجاني ✓ (إلغاء)" : "Free ✓ (undo)"
                                : lang === "ar" ? "اجعله مجاني" : "Make it free"}
                            </button>
                          )}
                          {line.original_price != null && (
                            <p className="truncate text-[10px] leading-none text-accent-foreground">
                              <span className="line-through tabular-nums">
                                {formatMoney(line.original_price, currency, lang)}
                              </span>{" "}
                              <span className="font-bold">{t("pos.offerBadge")}</span>
                            </p>
                          )}
                        </div>
                        {line.bundle_key ? (
                          // Combo lines are fixed: the server validates the exact bundle contents.
                          <span className="w-16 text-center text-xs font-bold tabular-nums">
                            {line.quantity}×
                          </span>
                        ) : (
                        <div className="flex h-7 items-center overflow-hidden rounded-md border border-input bg-background">
                          <Button
                            size="icon"
                            variant="ghost"
                            className="size-7 rounded-none"
                            onClick={() =>
                              setCart((prev) =>
                                prev.flatMap((l) =>
                                  l.key === line.key
                                    ? l.quantity > 1
                                      ? [{ ...l, quantity: l.quantity - 1 }]
                                      : []
                                    : [l],
                                ),
                              )
                            }
                            aria-label={lang === "ar" ? "تقليل الكمية" : "Decrease quantity"}
                          >
                            <Minus className="size-3" />
                          </Button>
                          <span className="w-5 text-center text-xs font-bold tabular-nums">
                            {line.quantity}
                          </span>
                          <Button
                            size="icon"
                            variant="ghost"
                            className="size-7 rounded-none"
                            onClick={() =>
                              setCart((prev) =>
                                prev.map((l) =>
                                  l.key === line.key ? { ...l, quantity: l.quantity + 1 } : l,
                                ),
                              )
                            }
                            aria-label={lang === "ar" ? "زيادة الكمية" : "Increase quantity"}
                          >
                            <Plus className="size-3" />
                          </Button>
                        </div>
                        )}
                        <span className="whitespace-nowrap text-end text-[11px] font-bold tabular-nums">
                          {formatMoney(
                            (line.unit_price +
                              line.modifiers.reduce((s, m) => s + Number(m.price_delta), 0)) *
                              line.quantity,
                            currency,
                            lang,
                          )}
                        </span>
                        <Button
                          size="icon"
                          variant="ghost"
                          className="size-7 text-destructive hover:text-destructive"
                          onClick={() =>
                            setCart((prev) =>
                              // Removing one combo line removes the whole combo.
                              line.bundle_key
                                ? prev.filter((l) => l.bundle_key !== line.bundle_key)
                                : prev.filter((l) => l.key !== line.key),
                            )
                          }
                          aria-label={lang === "ar" ? "حذف الصنف" : "Remove item"}
                        >
                          <X className="size-3.5" />
                        </Button>
                      </div>
                    ))}
                  </div>
                )}

                <Button type="button" variant="outline" className="w-full border-dashed" onClick={() => setCustomOpen(true)}>
                  <Plus className="size-4" /> {lang === "ar" ? "صنف يدوي حر" : "Custom item"}
                </Button>
                <Dialog open={customOpen} onOpenChange={setCustomOpen}>
                  <DialogContent className="max-w-sm">
                    <DialogHeader>
                      <DialogTitle>{lang === "ar" ? "صنف يدوي حر" : "Custom item"}</DialogTitle>
                    </DialogHeader>
                    <div className="grid gap-3">
                      <div className="grid gap-1">
                        <Label htmlFor="custom-name">{lang === "ar" ? "اسم الصنف" : "Item name"}</Label>
                        <Input id="custom-name" maxLength={80} value={customName} onChange={(e) => setCustomName(e.target.value)} />
                      </div>
                      <div className="grid grid-cols-2 gap-3">
                        <div className="grid gap-1">
                          <Label htmlFor="custom-price">{lang === "ar" ? "السعر (ج.م)" : "Price (EGP)"}</Label>
                          <Input id="custom-price" type="number" inputMode="decimal" min={0} step="0.5" value={customPrice} onChange={(e) => setCustomPrice(e.target.value)} />
                        </div>
                        <div className="grid gap-1">
                          <Label htmlFor="custom-qty">{lang === "ar" ? "الكمية" : "Quantity"}</Label>
                          <Input id="custom-qty" type="number" min={1} step="1" value={customQty} onChange={(e) => setCustomQty(e.target.value)} />
                        </div>
                      </div>
                    </div>
                    <DialogFooter>
                      <Button onClick={addCustomItem}>{lang === "ar" ? "إضافة للطلب" : "Add to order"}</Button>
                    </DialogFooter>
                  </DialogContent>
                </Dialog>

                {cart.length > 0 && (
                  <div className="grid gap-1">
                    <Label htmlFor="order-note">{lang === "ar" ? "ملاحظة على الطلب" : "Order note"}</Label>
                    <Input id="order-note" maxLength={500} value={orderNote} onChange={(e) => setOrderNote(e.target.value)} placeholder={lang === "ar" ? "مثال: سكر خفيف" : "e.g. less sugar"} />
                  </div>
                )}

                {can("pos.apply_discount") && cart.length > 0 && (
                  <div className="grid gap-2">
                    <div className="flex items-center justify-between">
                      <Label htmlFor="discount">{t("pos.discount")}</Label>
                      <div className="flex gap-1">
                        <Button type="button" size="sm" className="h-7 px-2" variant={discountMode === "amount" ? "default" : "outline"} onClick={() => setDiscountMode("amount")}>{currency}</Button>
                        <Button type="button" size="sm" className="h-7 px-2" variant={discountMode === "percent" ? "default" : "outline"} onClick={() => setDiscountMode("percent")}>%</Button>
                      </div>
                    </div>
                    <Input
                      id="discount"
                      inputMode="decimal"
                      value={discount}
                      onChange={(e) => setDiscount(e.target.value)}
                    />
                    {Number(discount) > 0 && (
                      <Input
                        placeholder={t("pos.discountReason")}
                        value={discountReason}
                        onChange={(e) => setDiscountReason(e.target.value)}
                      />
                    )}
                  </div>
                )}

                {orderType === "delivery" && (
                  <div className="grid gap-2 rounded-md border border-dashed border-border p-2">
                    <Label className="text-xs">
                      {lang === "ar" ? "بيانات التوصيل (إلزامية)" : "Delivery details (required)"}
                    </Label>
                    <Input
                      className="h-9"
                      placeholder={t("pos.customerName")}
                      value={customerName}
                      onChange={(e) => setCustomerName(e.target.value)}
                    />
                    <Input
                      className="h-9"
                      inputMode="tel"
                      placeholder={t("common.phone")}
                      value={customerPhone}
                      onChange={(e) => setCustomerPhone(e.target.value)}
                    />
                    {!customer && searchTerm && (
                      <CustomerSuggestionList
                        rows={customerSearch.data ?? []}
                        loading={customerSearch.isFetching}
                        lang={lang}
                        currency={currency}
                        onPick={pickCustomer}
                      />
                    )}
                  </div>
                )}
              </div>

              <div className="z-10 mt-auto shrink-0 space-y-2 border-t bg-card p-3">
                {rewardEligible && cart.length > 0 && (
                  <div className="flex items-center justify-between rounded-md bg-success/10 px-2 py-1 text-xs font-medium text-success">
                    <span>
                      {rewardLineKey
                        ? lang === "ar" ? "مشروب مجاني (مكافأة زيارات)" : "Free drink (visit reward)"
                        : lang === "ar" ? `العميل كمّل ${visitsNeeded} زيارات: اختار مشروب مجاني` : `${visitsNeeded} visits reached: pick a free drink`}
                    </span>
                    {rewardLineKey && <span className="tabular-nums">-{formatMoney(totals.rewardValue, currency, lang)}</span>}
                  </div>
                )}
                {cashbackOn && customer && cart.length > 0 && (
                  <div className="flex items-center justify-between rounded-md bg-secondary/60 px-2 py-1 text-xs font-medium">
                    <span>
                      {cashbackPreview.earn > 0
                        ? lang === "ar" ? "هيكسب كاش باك" : "Cashback earned"
                        : lang === "ar" ? "فاضل للكاش باك" : "Left to next cashback"}
                    </span>
                    <span className="tabular-nums">
                      {cashbackPreview.earn > 0 ? `+${formatMoney(cashbackPreview.earn, currency, lang)}` : formatMoney(cashbackPreview.left, currency, lang)}
                    </span>
                  </div>
                )}
                {cashbackOn && !customer && cart.length > 0 && !customerPhone.trim() && (
                  <p className="text-center text-[11px] text-muted-foreground">
                    {lang === "ar" ? "ضيف موبايل الزبون عشان المشتريات دي تتحسب له في الكاش باك" : "Add the customer phone so this bill counts toward cashback"}
                  </p>
                )}
                <div className="space-y-1 text-sm">
                  <Row
                    label={t("pos.subtotal")}
                    value={formatMoney(totals.subtotal, currency, lang)}
                  />
                  {totals.discountValue > 0 && (
                    <Row
                      label={t("pos.discount")}
                      value={`- ${formatMoney(totals.discountValue, currency, lang)}`}
                    />
                  )}
                  {totals.offersDiscount > 0 && (
                    <Row
                      label={t("pos.offersDiscount")}
                      value={`- ${formatMoney(totals.offersDiscount, currency, lang)}`}
                    />
                  )}
                  <div className="flex items-center justify-between pt-1 text-xl font-black text-primary">
                    <span>{t("common.total")}</span>
                    <span>{formatMoney(totals.total, currency, lang)}</span>
                  </div>
                </div>

                <Button
                  className="h-11 w-full text-base font-bold"
                  disabled={
                    cart.length === 0 ||
                    !can("pos.create_order") ||
                    startPayment.isPending ||
                    (!customerName.trim() && !customer && !partnerId)
                  }

                  onClick={() => startPayment.mutate()}
                >
                  {lang === "ar" ? "الدفع والتسديد" : "Pay & settle"}
                </Button>
                {!customerName.trim() && !customer && !partnerId && cart.length > 0 && (
                  <p className="text-center text-xs font-medium text-destructive">
                    {lang === "ar"
                      ? "اكتب اسم الزبون قبل الدفع"
                      : "Enter the customer name before paying"}
                  </p>
                )}
                {lastOrder && (
                  <p className="text-center text-xs text-muted-foreground">
                    {lang === "ar" ? "آخر فاتورة" : "Last invoice"}: #{lastOrder}
                  </p>
                )}
              </div>
            </CardContent>
          </Card>
        </div>
      )}

      {/* Product configuration */}
      <Dialog
        open={Boolean(configProduct)}
        onOpenChange={(open) => !open && setConfigProduct(null)}
      >
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {configProduct ? label(configProduct.name, configProduct.name_ar) : ""}
            </DialogTitle>
          </DialogHeader>
          {configProduct && (
            <div className="space-y-4">
              {configProduct.product_sizes.filter((s) => s.is_active).length > 0 && (
                <div className="space-y-2">
                  <Label>{t("menu.sizes")}</Label>
                  <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                    {needsBaseSize(configProduct) && (
                      <Button
                        className="h-auto min-h-14 flex-col gap-0.5"
                        variant={configSize === "" ? "default" : "outline"}
                        onClick={() => setConfigSize("")}
                      >
                        <span className="font-bold">{lang === "ar" ? "سينجل" : "Single"}</span>
                        <span className="text-xs tabular-nums opacity-80">
                          {formatMoney(Number(configProduct.base_price), currency, lang)}
                        </span>
                      </Button>
                    )}
                    {configProduct.product_sizes
                      .filter((s) => s.is_active)
                      .map((size) => (
                        <Button
                          key={size.id}
                          className="h-auto min-h-14 flex-col gap-0.5"
                          variant={configSize === size.id ? "default" : "outline"}
                          onClick={() => setConfigSize(size.id)}
                        >
                          <span className="font-bold">{label(size.name, size.name_ar)}</span>
                          <span className="text-xs tabular-nums opacity-80">
                            {formatMoney(
                              Number(configProduct.base_price) + Number(size.price_delta),
                              currency,
                              lang,
                            )}
                          </span>
                        </Button>
                      ))}
                  </div>
                </div>
              )}
              {activeGroups(configProduct).map((group) => (
                <div key={group.id} className="space-y-2">
                  <Label>
                    {label(group.name, group.name_ar)}
                    {group.min_select > 0 && <span className="text-destructive"> *</span>}
                  </Label>
                  <div className="flex flex-wrap gap-2">
                    {group.modifier_options
                      .filter((o) => o.is_active)
                      .map((option) => (
                        <Button
                          key={option.id}
                          size="sm"
                          variant={configMods[option.id] ? "default" : "outline"}
                          onClick={() =>
                            toggleMod(group, {
                              option_id: option.id,
                              name: label(option.name, option.name_ar),
                              price_delta: Number(option.price_delta),
                            })
                          }
                        >
                          {label(option.name, option.name_ar)}
                          {Number(option.price_delta) !== 0 &&
                            ` (+${formatMoney(option.price_delta, currency, lang)})`}
                        </Button>
                      ))}
                  </div>
                </div>
              ))}
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfigProduct(null)}>
              {t("common.cancel")}
            </Button>
            <Button onClick={confirmConfig}>{t("pos.addToCart")}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* General extras for any cart line */}
      <Dialog open={Boolean(extrasLine)} onOpenChange={(open) => !open && setExtrasLineKey(null)}>
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {lang === "ar" ? "إضافات" : "Extras"} — {extrasLine?.product_name}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            {(allGroups.data ?? []).length === 0 && <EmptyState message={lang === "ar" ? "لا توجد إضافات" : "No extras"} />}
            {(allGroups.data ?? []).map((group) => (
              <div key={group.id} className="space-y-2">
                <Label>{label(group.name, group.name_ar)}</Label>
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                  {group.modifier_options.filter((o) => o.is_active).map((option) => {
                    const on = extrasLine?.modifiers.some((m) => m.option_id === option.id);
                    return (
                      <Button
                        key={option.id}
                        className="h-auto min-h-12 flex-col gap-0.5"
                        variant={on ? "default" : "outline"}
                        onClick={() => toggleLineExtra({
                          option_id: option.id,
                          name: label(option.name, option.name_ar),
                          price_delta: Number(option.price_delta),
                        })}
                      >
                        <span className="font-bold">{label(option.name, option.name_ar)}</span>
                        <span className="text-xs tabular-nums opacity-80">
                          +{formatMoney(Number(option.price_delta), currency, lang)}
                        </span>
                      </Button>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
          <DialogFooter>
            <Button onClick={() => setExtrasLineKey(null)}>{t("common.confirm")}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Payment */}
      <Dialog open={payOpen} onOpenChange={setPayOpen}>
        <DialogContent className="max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t("pos.payment")}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div className="rounded-md bg-muted p-3 text-center">
              <p className="text-xs text-muted-foreground">{t("common.total")}</p>
              <p className="text-2xl font-bold">{formatMoney(totals.total, currency, lang)}</p>
            </div>

            <div className="grid gap-2 rounded-xl border border-border bg-card p-3 shadow-sm">
              <Label className="text-xs font-semibold">
                {lang === "ar" ? "طريقة الدفع" : "Payment type"}
              </Label>
              <div className="grid grid-cols-2 gap-2">
                <button
                  type="button"
                  onClick={() => {
                    setPartnerMode("paid");
                    setPartnerId("");
                  }}
                  className={`min-h-12 rounded-lg border px-3 py-2 text-sm font-bold ${
                    partnerMode === "paid" ? "border-primary bg-primary/10 text-primary" : "border-border"
                  }`}
                >
                  {lang === "ar" ? "دفع عادي" : "Regular payment"}
                </button>
                <button
                  type="button"
                  onClick={() => setPartnerMode("tab")}
                  className={`min-h-12 rounded-lg border px-3 py-2 text-sm font-bold ${
                    partnerMode === "tab" ? "border-accent bg-accent/20 text-accent-foreground" : "border-border"
                  }`}
                >
                  {lang === "ar" ? "على حساب الشريك" : "Partner account"}
                </button>
              </div>
              {partnerMode === "tab" && (
                <>
                  {(partners.data ?? []).length === 0 ? (
                    <p className="text-xs text-destructive">
                      {lang === "ar" ? "لا يوجد شركاء نشطون" : "No active partners"}
                    </p>
                  ) : (
                    <Select value={partnerId} onValueChange={setPartnerId}>
                      <SelectTrigger className="h-11">
                        <SelectValue placeholder={t("pos.selectPartner")} />
                      </SelectTrigger>
                      <SelectContent>
                        {(partners.data ?? []).map((partner) => (
                          <SelectItem key={partner.id} value={partner.id}>
                            {partner.name}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  )}
                  <p className="text-xs text-muted-foreground">{t("pos.partnerTabHint")}</p>
                </>
              )}
            </div>

            <div className={`space-y-3 ${onPartnerTab ? "hidden" : ""}`}>
              {customer && walletBalance > 0 && (
                <div className="flex animate-scale-in flex-wrap items-center justify-between gap-2 rounded-xl border border-accent/40 bg-gradient-to-br from-accent/15 to-accent/5 p-3">
                  <div className="flex items-center gap-3 text-sm">
                    <span className="flex size-10 items-center justify-center rounded-xl bg-gradient-accent text-accent-foreground shadow-sm" aria-hidden>
                      <Coins className="size-5" />
                    </span>
                    <div>
                    <p className="font-semibold">{lang === "ar" ? "رصيد كاش باك العميل" : "Customer cashback"}</p>
                    <p className="tabular-nums text-muted-foreground">
                      {formatMoney(walletBalance, currency, lang)}
                      {cashbackUsed > 0 && ` · ${lang === "ar" ? "مستخدم" : "used"} ${formatMoney(cashbackUsed, currency, lang)}`}
                    </p>
                    </div>
                  </div>
                  <Button type="button" icon={Coins} onClick={applyCashback}>
                    {lang === "ar" ? "استخدم الكاش باك" : "Use cashback"}
                  </Button>
                </div>
              )}
              {(methods.data ?? []).length > 0 && (
                <div className="grid gap-1.5">
                  <Label className="text-xs text-muted-foreground">
                    {lang === "ar" ? "ادفع الفاتورة كلها بـ" : "Pay the whole bill by"}
                  </Label>
                  <div className="flex flex-wrap gap-2">
                    {(methods.data ?? []).map((m) => {
                      const only = payRows.length === 1 && payRows[0]?.methodKey === m.key && payBalanced;
                      return (
                        <Button
                          key={m.id}
                          type="button"
                          size="sm"
                          variant={only ? "default" : "outline"}
                          className="min-h-10"
                          onClick={() => {
                            setPayRows(singleTender(m.key, totals.total, () => newPayRow(m.key).id));
                            if (m.key === "cash") setCashReceived(totals.total.toFixed(2));
                          }}
                        >
                          {tenderName(m.key, m.name, lang)}
                        </Button>
                      );
                    })}
                  </div>
                </div>
              )}
              {payRows.map((row, index) => {
                const method = methodByKey(row.methodKey);
                const isCashback = row.methodKey === "cashback";
                return (
                  <div
                    key={row.id}
                    className="space-y-2 rounded-lg border border-border p-2 transition-all duration-200"
                  >
                    <div className="flex items-end gap-2">
                      <div className="grid flex-1 gap-1">
                        <Label className="text-xs">
                          {t("pos.method")} {index + 1}
                        </Label>
                        <Select
                          value={row.methodKey}
                          onValueChange={(value) =>
                            setPayRows((prev) =>
                              prev.map((r) =>
                                r.id === row.id
                                  ? { ...r, methodKey: value, amount: "" }
                                  : r,
                              ),
                            )
                          }
                        >
                          <SelectTrigger className="h-11">
                            <SelectValue placeholder={t("pos.method")} />
                          </SelectTrigger>
                          <SelectContent>
                            {(methods.data ?? []).map((m) => (
                              <SelectItem key={m.id} value={m.key}>
                                {tenderName(m.key, m.name, lang)}
                              </SelectItem>
                            ))}
                            {customer && (walletBalance > 0 || isCashback) && (
                              <SelectItem value="cashback">
                                {lang === "ar" ? "🎁 كاش باك العميل" : "🎁 Customer cashback"}
                              </SelectItem>
                            )}
                          </SelectContent>
                        </Select>
                      </div>
                      <div className="grid w-28 gap-1">
                        <Label className="text-xs">
                          {t("common.total")}
                        </Label>
                        <Input
                          className="h-11"
                          inputMode="decimal"
                          value={row.amount}
                          onChange={(e) =>
                            setPayRows((prev) =>
                              prev.map((r) =>
                                r.id === row.id
                                  ? { ...r, amount: e.target.value }
                                  : r,
                              ),
                            )
                          }
                        />
                      </div>
                      {payRows.length > 1 && (
                        <Button
                          size="icon"
                          variant="ghost"
                          className="size-11 text-destructive hover:text-destructive"
                          onClick={() => setPayRows((prev) => prev.filter((r) => r.id !== row.id))}
                          aria-label={lang === "ar" ? "حذف طريقة السداد" : "Remove payment"}
                        >
                          <X className="size-4" />
                        </Button>
                      )}
                    </div>

                    {(method as { receiver_account?: string | null } | undefined)?.receiver_account && (
                      <p className="rounded-md bg-muted px-2 py-1 text-sm" dir="ltr">
                        <span className="text-muted-foreground">{lang === "ar" ? "حوّل على: " : "Send to: "}</span>
                        <b className="select-all">{(method as { receiver_account?: string | null }).receiver_account}</b>
                      </p>
                    )}
                    {isCashback && (
                      <p className="text-xs text-muted-foreground">
                        {lang === "ar"
                          ? `رصيد المحفظة: ${formatMoney(walletBalance, currency, lang)}`
                          : `Wallet balance: ${formatMoney(walletBalance, currency, lang)}`}
                      </p>
                    )}

                  </div>
                );
              })}

              <Button
                variant="outline"
                size="sm"
                className="w-full transition-all duration-200"
                onClick={() =>
                  setPayRows((prev) => {
                    const used = new Set(prev.map((r) => r.methodKey));
                    const next = (methods.data ?? []).find((m) => !used.has(m.key))?.key ?? "cash";
                    return addTender(prev, next, totals.total, () => newPayRow(next).id);
                  })
                }
              >
                <Plus className="me-1 size-4" />
                {lang === "ar" ? "إضافة طريقة سداد" : "Add payment method"}
              </Button>
            </div>

            <div
              className={`space-y-1 rounded-md border border-dashed border-border p-2 text-sm ${onPartnerTab ? "hidden" : ""}`}
            >
              <Row
                label={lang === "ar" ? "إجمالي المسدد" : "Payments total"}
                value={formatMoney(paidSum, currency, lang)}
              />
              <Row
                label={lang === "ar" ? "المتبقي" : "Remaining"}
                value={formatMoney(payRemaining, currency, lang)}
              />
            </div>

            {cashLine && !onPartnerTab && (
              <div className="grid gap-2">
                <Label htmlFor="paid">{t("pos.cashReceived")}</Label>
                <Input
                  id="paid"
                  inputMode="decimal"
                  value={cashReceived}
                  onChange={(e) => setCashReceived(e.target.value)}
                />
                <p className="text-sm text-muted-foreground">
                  {t("pos.change")}: {formatMoney(change, currency, lang)}
                </p>
              </div>
            )}

            {cashbackOver && (
              <p className="text-xs font-medium text-destructive">
                {lang === "ar"
                  ? `الكاش باك المستخدم أكبر من رصيد العميل (${formatMoney(walletBalance, currency, lang)})`
                  : `Cashback used exceeds the wallet (${formatMoney(walletBalance, currency, lang)})`}
              </p>
            )}
            {!payBalanced && !onPartnerTab && (
              <p className="text-xs font-medium text-destructive">
                {lang === "ar"
                  ? "لازم مجموع طرق السداد يساوي إجمالي الفاتورة بالظبط"
                  : "Payments must add up exactly to the order total"}
              </p>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPayOpen(false)}>
              {t("common.cancel")}
            </Button>
            <Button
              disabled={
                submitOrder.isPending ||
                (onPartnerTab && !partnerId) ||
                (!onPartnerTab &&
                  (payRows.length === 0 || !payBalanced || cashbackOver))
              }
              onClick={() => submitOrder.mutate()}
            >
              {onPartnerTab ? t("pos.confirmPartnerTab") : t("pos.confirmPayment")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Open shift */}
      <Dialog open={openCashOpen} onOpenChange={setOpenCashOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">{t("pos.openShift")}<InfoTip title="فتح الوردية">اكتب الفلوس الموجودة فعلاً في الدرج دلوقتي (الفكّة). ده رصيد البداية اللي هيتقارن بيه الدرج وقت القفل.</InfoTip></DialogTitle>
          </DialogHeader>
          <div className="grid gap-2">
            <Label htmlFor="opening">{t("pos.openingCash")}</Label>
            <Input
              id="opening"
              inputMode="decimal"
              value={openingCash}
              onChange={(e) => setOpeningCash(e.target.value)}
            />
          </div>
          <div className="grid gap-2">
            <Label>{lang === "ar" ? "طاقم الوردية" : "Shift roster"}</Label>
            <StaffPicker value={rosterIds} onChange={setRosterIds} lang={lang === "ar" ? "ar" : "en"} />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpenCashOpen(false)}>
              {t("common.cancel")}
            </Button>
            <Button disabled={openShift.isPending} onClick={() => openShift.mutate()}>
              {t("pos.openShift")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Close shift — slide-over */}
      <Sheet open={closeOpen} onOpenChange={setCloseOpen}>
        <SheetContent
          side={lang === "ar" ? "left" : "right"}
          className="flex h-full w-full flex-col gap-0 overflow-hidden border-border bg-card p-0 font-shift-body sm:max-w-xl"
        >
          <SheetHeader className="shrink-0 border-b border-border bg-card px-5 py-5 text-start sm:px-6">
            <div className="flex min-w-0 items-center gap-3 pe-10">
              <span className="grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm">
                <ReceiptText className="size-5" />
              </span>
              <div className="min-w-0">
                <SheetTitle className="flex items-center gap-2 truncate font-display text-xl font-bold">{t("pos.closeShift")}<InfoTip title="قفل الوردية">عدّ الفلوس اللي في الدرج واكتبها. السيستم بيطرح رصيد البداية والمبيعات الكاش، ولو فيه فرق بيقولك عجز ولا زيادة، وتحدد مين يتحمل العجز.</InfoTip></SheetTitle>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {lang === "ar" ? "راجع الإيرادات، طابق الدرج، ثم أكّد الإغلاق" : "Review revenue, reconcile the drawer, then confirm"}
                </p>
              </div>
            </div>
          </SheetHeader>
          <div className="shift-close-print min-h-0 flex-1 space-y-6 overflow-y-auto bg-muted px-4 py-5 sm:px-6">
            {shift.data?.id && (
              <ShiftPaymentBreakdown branchId={currentBranchId} shiftId={shift.data.id} currency={currency} lang={lang === "ar" ? "ar" : "en"} />
            )}
            {shift.data?.id && (refundsToDecide.data?.length ?? 0) > 0 && (
              <RefundBearerList
                shiftId={shift.data.id}
                refunds={refundsToDecide.data ?? []}
                staff={staffCandidates.data ?? []}
                canDecide={can("shifts.close")}
                currency={currency}
                lang={lang === "ar" ? "ar" : "en"}
              />
            )}
            {shiftRefunds.data && shiftRefunds.data.count > 0 && (
              <CollapsibleSection
                title={lang === "ar" ? "مرتجعات وهالك الوردية" : "Shift refunds & waste"}
                icon={<CircleAlert className="size-4" />}
                className="border-destructive/30 bg-destructive/10"
              >
                <Row
                  label={t("orders.refundedTotal")}
                  value={formatMoney(shiftRefunds.data.total, currency, lang)}
                />
                <Row
                  label={t("pos.cashRefunds")}
                  value={formatMoney(shiftRefunds.data.cash, currency, lang)}
                />
                <Row
                  label={t("refunds.waste")}
                  value={formatMoney(shiftRefunds.data.waste, currency, lang)}
                />
              </CollapsibleSection>
            )}
            {cashPreview.data && (
              <CollapsibleSection
                title={lang === "ar" ? "مطابقة درج النقدية" : "Cash drawer reconciliation"}
                icon={<Banknote className="size-4" />}
                className="border-primary/25 bg-card"
              >
                <Row
                  label={t("pos.openingCash")}
                  value={formatMoney(cashPreview.data.opening_cash, currency, lang)}
                />
                <Row
                  label={t("pos.cashIn")}
                  value={formatMoney(cashPreview.data.cash_in, currency, lang)}
                />
                <Row
                  label={t("pos.cashRefunds")}
                  value={`- ${formatMoney(cashPreview.data.cash_refunds, currency, lang)}`}
                />
                {Number(cashPreview.data.shift_expenses ?? 0) > 0 && (
                  <Row
                    label={lang === "ar" ? "مصروفات من الدرج" : "Drawer expenses"}
                    value={`- ${formatMoney(Number(cashPreview.data.shift_expenses), currency, lang)}`}
                  />
                )}
                <Row
                  label={t("pos.shiftSales")}
                  value={`${formatMoney(cashPreview.data.sales_total, currency, lang)} · ${cashPreview.data.orders_count} ${t("orders.count")}`}
                />
                <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-xl bg-primary/10 px-4 py-3 font-bold">
                  <span>{t("pos.expectedPreview")}</span>
                  <span className="font-display text-lg tabular-nums text-primary">{formatMoney(cashPreview.data.expected_cash, currency, lang)}</span>
                </div>
                {closingCash !== "" && (
                  <div className={`grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-xl px-4 py-3 font-bold ${closeShortage > 0 ? "bg-destructive/10 text-destructive" : "bg-success/10 text-success"}`}>
                    <span>{t("pos.varianceNow")}</span>
                    <span className="font-display text-lg tabular-nums">
                      {formatMoney((Number(closingCash) || 0) - cashPreview.data.expected_cash, currency, lang)}
                    </span>
                  </div>
                )}
              </CollapsibleSection>
            )}
            <CollapsibleSection
              title={lang === "ar" ? "أدخل العد الفعلي" : "Enter the actual count"}
              description={lang === "ar" ? "اكتب المبلغ الموجود فعليًا في الدرج" : "Enter the cash physically present in the drawer"}
              icon={<Calculator className="size-4" />}
              className="border-primary/25 bg-card p-4 sm:p-5"
            >
              <div className="grid gap-5">
                <div className="grid gap-2.5 rounded-2xl border border-primary/25 bg-primary/5 p-4">
                  <Label htmlFor="closing" className="flex items-center gap-2 text-sm font-bold text-primary">
                    <Banknote className="size-4" />
                    {t("pos.closingCash")}
                  </Label>
                  <div className="relative">
                    <Input
                      id="closing"
                      inputMode="decimal"
                      value={closingCash}
                      onChange={(e) => setClosingCash(e.target.value)}
                      placeholder="0"
                      className="h-16 rounded-2xl border-primary/30 bg-background pe-20 ps-5 font-display text-2xl font-black tabular-nums shadow-sm focus-visible:ring-primary"
                    />
                    <span className="absolute inset-y-0 end-4 grid place-items-center text-sm font-bold text-muted-foreground">{currency}</span>
                  </div>
                </div>
                <div className="grid gap-2.5 rounded-2xl border border-accent/40 bg-accent/5 p-4">
                  <Label htmlFor="retained" className="flex items-center gap-2 text-sm font-bold text-accent-foreground">
                    <Wallet className="size-4" />
                    {lang === "ar" ? "الفكة المتبقية للوردية القادمة" : "Retained float for next shift"}
                  </Label>
                  <div className="relative">
                    <Input
                      id="retained"
                      inputMode="decimal"
                      value={retainedFloat}
                      onChange={(e) => setRetainedFloat(e.target.value)}
                      placeholder="0"
                      className="h-14 rounded-2xl border-accent/40 bg-background pe-20 ps-5 font-display text-xl font-black tabular-nums shadow-sm focus-visible:ring-accent"
                    />
                    <span className="absolute inset-y-0 end-4 grid place-items-center text-sm font-bold text-muted-foreground">{currency}</span>
                  </div>
                </div>
                {closingCash !== "" && retainedFloat !== "" && (
                  <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-2xl bg-accent/15 px-5 py-4">
                    <span className="text-sm font-bold text-foreground">{lang === "ar" ? "المبلغ المورد للخزينة" : "Cash drop to safe"}</span>
                    <span className="shrink-0 font-display text-2xl font-black tabular-nums text-accent-foreground">
                      {formatMoney(Math.max(0, (Number(closingCash) || 0) - (Number(retainedFloat) || 0)), currency, lang)}
                    </span>
                  </div>
                )}
                {closingCash !== "" && closeShortage > 0 && (
                  <div className="grid gap-4 rounded-2xl border border-destructive/30 bg-destructive/5 p-5">
                    <div className="grid gap-1">
                      <p className="font-display text-base font-bold text-destructive">
                        {lang === "ar" ? "عجز في الدرج — اختر طريقة التحميل" : "Drawer shortage — choose who carries it"}
                      </p>
                      <p className="text-sm text-muted-foreground">
                        {lang === "ar"
                          ? `العجز ${formatMoney(closeShortage, currency, lang)} — لن تُغلق الوردية قبل تحديد من يتحمله`
                          : `Shortage ${formatMoney(closeShortage, currency, lang)} — the shift cannot close until it is attributed`}
                      </p>
                    </div>
                    <div className="grid gap-2.5">
                      {([
                        {
                          key: "split" as ShortageMode,
                          label: lang === "ar" ? "توزيع بالتساوي على طاقم الوردية" : "Split equally across shift staff",
                          hint: lang === "ar" ? `${shortageStaff.length} موظف — جزاء معلّق لكل منهم` : `${shortageStaff.length} staff — pending penalty each`,
                          disabled: false,
                        },
                        {
                          key: "staff" as ShortageMode,
                          label: lang === "ar" ? "تحميل على موظف محدد" : "Charge one staff member",
                          hint: lang === "ar" ? "جزاء معلّق بكامل العجز" : "Pending penalty for the full shortage",
                          disabled: false,
                        },
                        {
                          key: "venue" as ShortageMode,
                          label: lang === "ar" ? "تحمل المكان" : "Venue absorbed",
                          hint: canAbsorbShortage
                            ? lang === "ar" ? "فرق تشغيل معتمد من الإدارة — يُخصم من صافي ربح الفترة" : "Manager-approved operating variance — deducted from period net profit"
                            : lang === "ar" ? "يتطلب صلاحية مدير أو شريك" : "Requires a manager or partner",
                          disabled: !canAbsorbShortage,
                        },
                      ]).map((option) => (
                        <button
                          key={option.key}
                          type="button"
                          disabled={option.disabled}
                          onClick={() => setShortageMode(option.key)}
                          className={`min-h-16 rounded-xl border p-4 text-start transition disabled:cursor-not-allowed disabled:opacity-50 ${
                            shortageMode === option.key
                              ? "border-destructive bg-destructive/10 shadow-sm"
                              : "border-border bg-card hover:bg-muted"
                          }`}
                        >
                          <p className="font-display text-sm font-bold text-foreground">{option.label}</p>
                          <p className="mt-0.5 text-xs text-muted-foreground">{option.hint}</p>
                        </button>
                      ))}
                    </div>
                    {shortageMode === "staff" && (
                      <select
                        value={shortageStaffId}
                        onChange={(e) => setShortageStaffId(e.target.value)}
                        className="h-12 rounded-xl border border-input bg-background px-4 text-base"
                      >
                        <option value="">{lang === "ar" ? "اختر الموظف" : "Select staff"}</option>
                        {shortageStaff.map((person) => (
                          <option key={person.id} value={person.id}>
                            {person.name}
                          </option>
                        ))}
                      </select>
                    )}
                    {shortageMode === "venue" && (
                      <div className="grid gap-2.5">
                        <Label htmlFor="venue-shortage-reason" className="text-sm font-bold">
                          {lang === "ar" ? "سبب تحميل العجز على المكان (إلزامي)" : "Reason for venue-absorbed shortage (required)"}
                        </Label>
                        <Textarea
                          id="venue-shortage-reason"
                          value={venueReason}
                          onChange={(e) => setVenueReason(e.target.value)}
                          maxLength={300}
                          placeholder={
                            lang === "ar"
                              ? "اكتب سببًا واضحًا، مثال: فرق بسبب خطأ في عد النقدية"
                              : "Write a clear reason, e.g. cash counting discrepancy"
                          }
                          aria-invalid={trimmedVenueReason.length > 0 && !venueReasonValid}
                          className="min-h-24 rounded-xl bg-background text-base"
                        />
                        {!venueReasonValid && (
                          <p className="text-xs text-destructive">
                            {lang === "ar"
                              ? "السبب إلزامي ويجب أن يكون كلامًا واضحًا، وليس نقطة أو أرقامًا فقط."
                              : "A clear written reason is required; punctuation or numbers alone are not accepted."}
                          </p>
                        )}
                      </div>
                    )}
                  </div>
                )}
                <div className="grid gap-2.5">
                  <Label htmlFor="close-notes" className="text-sm font-bold">
                    {t("common.notes")}
                  </Label>
                  <Input
                    id="close-notes"
                    value={closeNotes}
                    onChange={(e) => setCloseNotes(e.target.value)}
                    className="h-12 rounded-xl bg-background"
                  />
                </div>
              </div>
            </CollapsibleSection>
            <div className="flex items-start gap-2 rounded-xl bg-muted p-3 text-xs text-muted-foreground print:hidden">
              <ShieldCheck className="mt-0.5 size-4 shrink-0 text-primary" />
              <p>{t("pos.closeHint")}</p>
            </div>
          </div>
          <SheetFooter className="shrink-0 gap-2 border-t border-border bg-card px-4 py-4 sm:flex-col sm:space-x-0 sm:px-6 print:hidden">
            <Button
              type="button"
              variant="outline"
              className="h-11 w-full rounded-xl transition-all duration-200"
              onClick={handlePrintClose}
            >
              <Printer className="size-4" />
              {lang === "ar" ? "طباعة تقرير إغلاق الوردية" : "Print shift close report"}
            </Button>
            <Button
              disabled={
                closeShift.isPending ||
                (refundsToDecide.data?.length ?? 0) > 0 ||
                closingCash === "" ||
                retainedFloat === "" ||
                (closeShortage > 0 &&
                  ((shortageMode === "staff" && !shortageStaffId) ||
                    (shortageMode === "split" && shortageStaff.length === 0) ||
                    (shortageMode === "venue" && !venueReasonValid)))
              }
              className="h-12 w-full rounded-xl bg-primary font-bold text-primary-foreground shadow-sm transition-all duration-200 hover:bg-primary/90"
              onClick={requestClose}
            >
              {t("pos.closeShift")}
            </Button>
            <Button
              variant="outline"
              className="h-11 w-full rounded-xl transition-all duration-200"
              onClick={() => setCloseOpen(false)}
            >
              {t("common.cancel")}
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      {shift.data && (
        <>
          <ShiftRosterDialog
            shiftId={shift.data.id}
            open={rosterOpen}
            onOpenChange={setRosterOpen}
            lang={lang === "ar" ? "ar" : "en"}
          />
          <ShiftExpenseDialog
            shiftId={shift.data.id}
            shiftLabel={shift.data.id.slice(0, 8)}
            open={expenseOpen}
            onOpenChange={setExpenseOpen}
            lang={lang === "ar" ? "ar" : "en"}
          />
        </>
      )}

      {bundleLightbox && (
        <div
          role="presentation"
          className="fixed inset-0 z-50 grid place-items-center bg-black/50 p-4"
          onClick={() => setBundleLightbox(null)}
        >
          <Button
            type="button"
            size="icon"
            variant="secondary"
            aria-label={t("common.close")}
            className="absolute end-4 top-4"
            onClick={(e) => {
              e.stopPropagation();
              setBundleLightbox(null);
            }}
          >
            <X className="size-4" />
          </Button>
          <img
            src={bundleLightbox.src}
            alt={bundleLightbox.alt}
            className="max-h-[85vh] max-w-full rounded-xl object-contain shadow-2xl"
          />
        </div>
      )}
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex min-w-0 items-center justify-between gap-3 py-0.5">
      <span className="min-w-0 truncate text-sm text-muted-foreground">{label}</span>
      <span className="shrink-0 text-base font-bold tabular-nums text-foreground">{value}</span>
    </div>
  );
}

/** Live KPI strip for the open shift; money comes from the shared finance engine. */
function PosShiftKpis({ branchId, shiftId, currency, lang }: { branchId: string; shiftId: string; currency: string; lang: "ar" | "en" }) {
  const ar = lang === "ar";
  const engine = useFinancialEngine({ branchId, shiftIds: [shiftId] });
  const count = useQuery({
    queryKey: ["pos-shift-order-count", shiftId],
    refetchInterval: 30000,
    queryFn: async () => {
      const { count, error } = await supabase
        .from("orders")
        .select("id", { count: "exact", head: true })
        .eq("shift_id", shiftId)
        .neq("status", "cancelled");
      if (error) throw error;
      return count ?? 0;
    },
  });
  const s = engine.data?.byShift.get(shiftId);
  const money = (v: number | undefined) => (v === undefined ? "—" : formatMoney(v, currency, lang));
  return (
    <KpiGrid cols={4}>
      <KpiCard label={ar ? "إجمالي مبيعات الوردية" : "Shift sales"} value={money(s?.netSales)} tone="brand" formula={ar ? "الإجمالي − العروض − الخصومات − المرتجعات." : "Gross − offers − discounts − refunds."} />
      <KpiCard label={ar ? "عدد الطلبات" : "Orders"} value={count.data ?? "—"} formula={ar ? "عدد فواتير الوردية غير الملغاة." : "Non-cancelled invoices in this shift."} />
      <KpiCard label={ar ? "النقدية المتوقعة في الدرج" : "Expected drawer cash"} value={money(s?.expectedCash)} formula={ar ? "عهدة الفتح + مبيعات الكاش − مرتجعات الكاش − مصروفات الوردية." : "Opening float + cash sales − cash refunds − shift expenses."} />
      <KpiCard
        label={ar ? "عجز / زيادة النقدية" : "Short / over"}
        value={s?.variance === null || s?.variance === undefined ? (ar ? "عند الإغلاق" : "At close") : money(s.variance)}
        tone={s?.variance ? (s.variance < 0 ? "bad" : "good") : undefined}
        formula={ar ? "النقدية المعدودة عند الإغلاق − النقدية المتوقعة." : "Counted closing cash − expected cash."}
      />
    </KpiGrid>
  );
}
