import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, createFileRoute } from "@tanstack/react-router";
import { Trash2, Upload, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
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
import { Switch } from "@/components/ui/switch";
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
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { buildProductPlan, tierLabel, type PlanTier } from "@/lib/product-plan";

export const Route = createFileRoute("/_authenticated/offers")({
  head: () => ({
    meta: [
      { title: "Offers & combos — 20s Coffee" },
      {
        name: "description",
        content:
          "Build single-item offers and combo bundles with a live profit advisor that blocks any price under the safety floor.",
      },
      { property: "og:title", content: "Offers & combos — 20s Coffee" },
      {
        property: "og:description",
        content: "Bundle builder, live ingredient cost, and profit margin guard for every offer.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: OffersPage,
});

type Candidate = {
  product_id: string;
  name: string;
  name_ar: string | null;
  image_url: string | null;
  base_price: number | string | null;
  unit_cost: number | string | null;
  qty: number | string | null;
  revenue: number | string | null;
  margin: number | string | null;
  safe_floor: number | string | null;
};

type BundleDraft = { product_id: string; quantity: number };

const num = (v: number | string | null | undefined) => {
  const n = typeof v === "string" ? Number(v) : (v ?? 0);
  return Number.isFinite(n) ? Number(n) : 0;
};
const half = (n: number) => Math.round(n * 2) / 2;

function isoDaysAgo(days: number) {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().slice(0, 10);
}

/** Suggested offer price: attractive discount but never under the safe floor. */
function suggestPrice(price: number, cost: number, floor: number) {
  const safeFloor = Math.max(floor, half(cost * 1.25));
  const target = half(price * 0.85);
  return Math.max(safeFloor, target > 0 ? target : safeFloor);
}

function OffersPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  const canView = can("products.view") || can("analytics.view");
  const canManage = can("products.update") || can("products.create");

  const from = isoDaysAgo(30);
  const to = new Date().toISOString().slice(0, 10);
  const money = (v: number) => formatMoney(v, currency, lang);

  const candidates = useQuery({
    queryKey: ["offer-candidates", from, to],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("offer_candidates", { _from: from, _to: to });
      if (error) throw error;
      return (data ?? []) as Candidate[];
    },
  });

  const productList = useQuery({
    queryKey: ["offer-products"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("products")
        .select("id, name, name_ar, base_price")
        .eq("is_active", true)
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const offers = useQuery({
    queryKey: ["product-offers"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("product_offers")
        .select(
          "id, title, offer_type, image_path, offer_price, base_price_snapshot, unit_cost_snapshot, double_points, starts_at, ends_at, is_active, notes, product_id, products(name, name_ar), offer_bundle_items(product_id, quantity, products(name, name_ar))",
        )
        .order("created_at", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  // Offer banners live in a private bucket, so sign them for the admin table.
  const offerImages = useQuery({
    queryKey: ["offer-image-urls", (offers.data ?? []).map((o) => o.image_path).join("|")],
    enabled: canView && (offers.data ?? []).some((o) => o.image_path),
    queryFn: async () => {
      const paths = (offers.data ?? [])
        .map((o) => o.image_path)
        .filter((p): p is string => Boolean(p));
      const map = new Map<string, string>();
      if (paths.length === 0) return map;
      const { data } = await supabase.storage.from("offer-images").createSignedUrls(paths, 3600);
      for (const row of data ?? []) {
        if (row.path && row.signedUrl) map.set(row.path, row.signedUrl);
      }
      return map;
    },
  });

  const masterToggle = useQuery({
    queryKey: ["offers-master-toggle"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("offers_enabled", {});
      if (error) throw error;
      return Boolean(data);
    },
  });

  const customers = useQuery({
    queryKey: ["offer-customers"],
    enabled: canView && can("loyalty.view"),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("customers")
        .select("id, code, name, phone, wallet_balance, total_spent, visits")
        .eq("is_active", true)
        .order("total_spent", { ascending: false })
        .limit(25);
      if (error) throw error;
      return data ?? [];
    },
  });

  const rows = useMemo(() => {
    const list = (candidates.data ?? []).map((row) => ({
      ...row,
      price: num(row.base_price),
      cost: num(row.unit_cost),
      sold: num(row.qty),
      floor: num(row.safe_floor),
    }));
    const maxQty = list.reduce((max, r) => Math.max(max, r.sold), 0);
    const star = [...list].sort((a, b) => b.sold - a.sold)[0] ?? null;
    return list.map((row) => ({
      ...row,
      suggested: suggestPrice(row.price, row.cost, row.floor),
      plan: buildProductPlan(
        {
          name: row.name,
          name_ar: row.name_ar,
          qty: row.sold,
          revenue: num(row.revenue),
          cost: num(row.cost) * row.sold,
          margin: num(row.margin),
          base_price: row.price,
          unit_cost: row.cost,
        },
        {
          maxQty,
          star: star
            ? {
                name: star.name,
                name_ar: star.name_ar,
                qty: star.sold,
                revenue: num(star.revenue),
                cost: num(star.unit_cost),
                margin: num(star.margin),
                base_price: num(star.base_price),
                unit_cost: num(star.unit_cost),
              }
            : null,
          currency,
          lang,
        },
      ),
    }));
  }, [candidates.data, currency, lang]);

  const [search, setSearch] = useState("");
  const [planFor, setPlanFor] = useState<string | null>(null);
  const [lightbox, setLightbox] = useState<{ src: string; alt: string } | null>(null);

  // Escape closes the high-resolution preview.
  useEffect(() => {
    if (!lightbox) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setLightbox(null);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [lightbox]);

  // ===== Offer builder state =====
  const [formOpen, setFormOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [mode, setMode] = useState<"single" | "bundle">("single");
  const [productId, setProductId] = useState("");
  const [bundle, setBundle] = useState<BundleDraft[]>([]);
  const [title, setTitle] = useState("");
  const [price, setPrice] = useState("");
  const [doublePoints, setDoublePoints] = useState(false);
  const [starts, setStarts] = useState(to);
  const [ends, setEnds] = useState("");
  const [notes, setNotes] = useState("");
  const [imagePath, setImagePath] = useState<string | null>(null);
  const [imageUrl, setImageUrl] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const name = (row: { name: string; name_ar: string | null }) =>
    lang === "ar" ? row.name_ar || row.name : row.name;
  const productName = (id: string) => {
    const p = (productList.data ?? []).find((row) => row.id === id);
    return p ? name(p) : "—";
  };

  const advisorPayload = useMemo(
    () => ({
      offer_type: mode,
      ...(mode === "single" ? { product_id: productId || null, quantity: 1 } : {}),
      items: mode === "bundle" ? bundle.filter((b) => b.product_id) : [],
    }),
    [mode, productId, bundle],
  );

  // Financial advisor numbers come from the same server function that guards the save.
  const advisor = useQuery({
    queryKey: ["offer-preview", JSON.stringify(advisorPayload)],
    enabled:
      formOpen &&
      (mode === "single"
        ? Boolean(productId)
        : bundle.filter((b) => b.product_id).length >= 2),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("offer_price_preview", {
        _payload: advisorPayload,
      });
      if (error) throw error;
      const row = (data ?? [])[0];
      return {
        base_total: num(row?.base_total),
        live_cost: num(row?.live_cost),
        safe_floor: num(row?.safe_floor),
        normal_profit: num(row?.normal_profit),
        normal_margin: num(row?.normal_margin),
      };
    },
  });

  const offerPrice = Number(price) || 0;
  const base = advisor.data?.base_total ?? 0;
  const cogs = advisor.data?.live_cost ?? 0;
  const safeFloor = advisor.data?.safe_floor ?? 0;
  const newProfit = offerPrice - cogs;
  const newMargin = offerPrice > 0 ? (newProfit / offerPrice) * 100 : 0;
  const saving = Math.max(0, base - offerPrice);
  const savingPct = base > 0 ? (saving / base) * 100 : 0;
  const belowFloor = !advisor.data || offerPrice <= 0 || offerPrice < safeFloor;

  // The price field is fully user-owned; the suggestion is applied only via its explicit button.

  function resetForm() {
    setEditingId(null);
    setMode("single");
    setProductId("");
    setBundle([]);
    setTitle("");
    setPrice("");
    setDoublePoints(false);
    setStarts(to);
    setEnds("");
    setNotes("");
    setImagePath(null);
    setImageUrl(null);
  }

  function openNew(seed?: { product_id: string; label: string; suggested: number }) {
    resetForm();
    if (seed) {
      setProductId(seed.product_id);
      setTitle(`${seed.label} — ${t("off.offer")}`);
      setPrice(String(seed.suggested));
    }
    setFormOpen(true);
  }

  async function openEdit(offer: NonNullable<typeof offers.data>[number]) {
    resetForm();
    setEditingId(offer.id);
    setMode(offer.offer_type === "bundle" ? "bundle" : "single");
    setProductId(offer.product_id ?? "");
    setBundle(
      (offer.offer_bundle_items ?? []).map((row) => ({
        product_id: row.product_id,
        quantity: Number(row.quantity),
      })),
    );
    setTitle(offer.title);
    setPrice(String(num(offer.offer_price)));
    setDoublePoints(Boolean(offer.double_points));
    setStarts(offer.starts_at);
    setEnds(offer.ends_at ?? "");
    setNotes(offer.notes ?? "");
    setImagePath(offer.image_path ?? null);
    if (offer.image_path) {
      const { data } = await supabase.storage
        .from("offer-images")
        .createSignedUrl(offer.image_path, 3600);
      setImageUrl(data?.signedUrl ?? null);
    }
    setFormOpen(true);
  }

  const uploadImage = useMutation({
    mutationFn: async (file: File) => {
      const ext = file.name.split(".").pop()?.toLowerCase() || "jpg";
      const path = `${me!.profile.company_id}/${crypto.randomUUID()}.${ext}`;
      const { error } = await supabase.storage.from("offer-images").upload(path, file, {
        cacheControl: "3600",
        upsert: false,
      });
      if (error) throw error;
      const { data } = await supabase.storage.from("offer-images").createSignedUrl(path, 3600);
      return { path, url: data?.signedUrl ?? null };
    },
    onSuccess: async ({ path, url }) => {
      if (imagePath) await supabase.storage.from("offer-images").remove([imagePath]);
      setImagePath(path);
      setImageUrl(url);
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const save = useMutation({
    mutationFn: async () => {
      const items = bundle.filter((b) => b.product_id);
      if (mode === "bundle" && items.length < 2) throw new Error(t("off.bundleNeedsTwo"));
      const { error } = await supabase.rpc("save_product_offer", {
        _payload: {
          ...(editingId ? { id: editingId } : {}),
          offer_type: mode,
          product_id: mode === "single" ? productId : null,
          items: mode === "bundle" ? items : [],
          title: title.trim(),
          offer_price: offerPrice,
          double_points: doublePoints,
          starts_at: starts,
          ends_at: ends || null,
          notes: notes.trim() || null,
          image_path: imagePath,
        },
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setFormOpen(false);
      resetForm();
      await queryClient.invalidateQueries({ queryKey: ["product-offers"] });
      toast.success(t("off.saved"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const toggle = useMutation({
    mutationFn: async (offer: { id: string; is_active: boolean }) => {
      const { error } = await supabase.rpc("set_offer_active", {
        _offer_id: offer.id,
        _active: !offer.is_active,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["product-offers"] });
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const setMaster = useMutation({
    mutationFn: async (enabled: boolean) => {
      const { error } = await supabase.rpc("set_offers_enabled", { _enabled: enabled });
      if (error) throw error;
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["offers-master-toggle"] });
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const filtered = rows.filter((row) =>
    search.trim() ? name(row).toLowerCase().includes(search.trim().toLowerCase()) : true,
  );
  const active = rows.find((r) => r.product_id === planFor) ?? null;

  const tierVariant: Record<PlanTier, "default" | "secondary" | "outline" | "destructive"> = {
    star: "default",
    steady: "secondary",
    thin: "outline",
    slow: "outline",
    dead: "destructive",
  };

  const today = to;
  const allOffers = offers.data ?? [];
  const runningOffers = allOffers.filter(
    (o) => o.is_active && (!o.ends_at || o.ends_at >= today),
  );
  const pastOffers = allOffers.filter((o) => !o.is_active || (o.ends_at && o.ends_at < today));

  const itemsLabel = (offer: (typeof allOffers)[number]) => {
    if (offer.offer_type === "bundle") {
      const items = offer.offer_bundle_items ?? [];
      return items.length > 0
        ? items
            .map((row) => `${row.quantity}× ${row.products ? name(row.products) : "—"}`)
            .join(" + ")
        : "—";
    }
    return offer.products ? name(offer.products) : "—";
  };

  const offerTable = (list: typeof allOffers) => (
    <div className="-mx-4 overflow-x-auto px-4">
      <Table className="min-w-[1100px]">
        <TableHeader>
          <TableRow>
            <TableHead className="w-[70px] text-center">{t("off.thumbnail")}</TableHead>
            <TableHead className="text-start">{t("off.offer")}</TableHead>
            <TableHead className="w-[120px] text-center">{t("off.type")}</TableHead>
            <TableHead className="text-start">{t("off.items")}</TableHead>
            <TableHead className="text-end">{t("off.price")}</TableHead>
            <TableHead className="text-end">{t("off.offerPrice")}</TableHead>
            <TableHead className="text-end">{t("off.marginPct")}</TableHead>
            <TableHead className="w-[200px] text-center">{t("off.period")}</TableHead>
            <TableHead className="text-end">{t("common.actions")}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {list.map((offer) => {
            const op = num(offer.offer_price);
            const oc = num(offer.unit_cost_snapshot);
            const profit = op - oc;
            const pct = op > 0 ? (profit / op) * 100 : 0;
            const src = offer.image_path ? offerImages.data?.get(offer.image_path) : undefined;
            return (
              <TableRow key={offer.id} className="odd:bg-muted/30">
                <TableCell className="text-center">
                  {src ? (
                    <button
                      type="button"
                      onClick={() => setLightbox({ src, alt: offer.title })}
                      className="mx-auto block"
                    >
                      <img
                        src={src}
                        alt={offer.title}
                        className="size-10 rounded-md object-cover"
                      />
                    </button>
                  ) : (
                    <span className="text-muted-foreground">—</span>
                  )}
                </TableCell>
                <TableCell className="text-start font-medium">{offer.title}</TableCell>
                <TableCell className="text-center">
                  <Badge variant={offer.offer_type === "bundle" ? "default" : "secondary"}>
                    {offer.offer_type === "bundle" ? t("off.modeBundle") : t("off.modeSingle")}
                  </Badge>
                </TableCell>
                <TableCell className="text-start text-xs text-muted-foreground">
                  {itemsLabel(offer)}
                </TableCell>
                <TableCell className="whitespace-nowrap text-end font-mono tabular-nums">
                  {money(num(offer.base_price_snapshot))}
                </TableCell>
                <TableCell className="whitespace-nowrap text-end font-mono font-semibold tabular-nums text-primary">
                  {money(op)}
                </TableCell>
                <TableCell className="whitespace-nowrap text-end font-mono tabular-nums">
                  <span className={profit <= 0 ? "text-destructive" : ""}>{money(profit)}</span>{" "}
                  <span className="text-xs text-muted-foreground">({pct.toFixed(0)}%)</span>
                </TableCell>
                <TableCell className="whitespace-nowrap text-center text-xs text-muted-foreground">
                  {offer.starts_at} → {offer.ends_at ?? "—"}
                </TableCell>
                <TableCell className="text-end">
                  <div className="flex items-center justify-end gap-3">
                    <Switch
                      checked={offer.is_active}
                      disabled={!canManage || toggle.isPending}
                      onCheckedChange={() =>
                        toggle.mutate({ id: offer.id, is_active: offer.is_active })
                      }
                    />
                    {canManage && (
                      <Button size="sm" variant="outline" onClick={() => void openEdit(offer)}>
                        {t("common.edit")}
                      </Button>
                    )}
                  </div>
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );

  return (
    <div className="space-y-6">
      <PageHeader title={t("off.title")} description={t("off.subtitle")} />

      <Card>
        <CardContent className="flex flex-wrap items-center justify-between gap-3 py-4">
          <div>
            <p className="text-sm font-medium">{t("settings.offersMaster")}</p>
            <p className="text-xs text-muted-foreground">{t("settings.offersMasterHint")}</p>
          </div>
          <div className="flex items-center gap-3">
            <Badge variant={masterToggle.data ? "default" : "destructive"}>
              {masterToggle.data ? t("common.active") : t("common.inactive")}
            </Badge>
            <Switch
              checked={Boolean(masterToggle.data)}
              disabled={!can("settings.manage") || setMaster.isPending}
              onCheckedChange={(v) => setMaster.mutate(v)}
            />
          </div>
        </CardContent>
      </Card>

      <Tabs defaultValue="build" className="space-y-4">
        <div className="-mx-2 overflow-x-auto px-2">
          <TabsList>
            <TabsTrigger value="build">{t("off.tabBuild")}</TabsTrigger>
            <TabsTrigger value="active">{t("off.tabActive")}</TabsTrigger>
            <TabsTrigger value="expired">{t("off.tabExpired")}</TabsTrigger>
            <TabsTrigger value="customers">{t("off.tabCustomers")}</TabsTrigger>
          </TabsList>
        </div>

        {/* Build offers */}
        <TabsContent value="build" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-row flex-wrap items-center justify-between gap-3">
              <CardTitle>{t("off.pick")}</CardTitle>
              <div className="flex flex-wrap items-center gap-2">
                <Input
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder={t("off.searchProduct")}
                  className="w-full sm:w-64"
                />
                {canManage && <Button onClick={() => openNew()}>{t("off.newOffer")}</Button>}
              </div>
            </CardHeader>
            <CardContent>
              {filtered.length === 0 ? (
                <EmptyState message={t("off.noData")} />
              ) : (
                <div className="-mx-4 overflow-x-auto px-4">
                  <Table className="min-w-[1000px]">
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-start">{t("off.product")}</TableHead>
                        <TableHead className="text-end">{t("off.price")}</TableHead>
                        <TableHead className="text-end">{t("off.cost")}</TableHead>
                        <TableHead className="text-end">{t("off.sold")}</TableHead>
                        <TableHead className="text-end">{t("off.floor")}</TableHead>
                        <TableHead className="text-end">{t("off.suggested")}</TableHead>
                        <TableHead className="text-end">{t("off.profitAtSuggested")}</TableHead>
                        <TableHead className="w-[120px] text-center">{t("off.status")}</TableHead>
                        <TableHead className="text-end">{t("common.actions")}</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {filtered.map((row) => {
                        const profit = row.suggested - row.cost;
                        const pct = row.suggested > 0 ? (profit / row.suggested) * 100 : 0;
                        return (
                          <TableRow key={row.product_id} className="odd:bg-muted/30">
                            <TableCell className="text-start font-medium">{name(row)}</TableCell>
                            <TableCell className="text-end font-mono tabular-nums">
                              {money(row.price)}
                            </TableCell>
                            <TableCell className="text-end font-mono tabular-nums">
                              {money(row.cost)}
                            </TableCell>
                            <TableCell className="text-end font-mono tabular-nums">
                              {row.sold}
                            </TableCell>
                            <TableCell className="text-end font-mono tabular-nums">
                              {money(Math.max(row.floor, row.cost * 1.25))}
                            </TableCell>
                            <TableCell className="text-end font-mono font-semibold tabular-nums text-primary">
                              {money(row.suggested)}
                            </TableCell>
                            <TableCell className="whitespace-nowrap text-end font-mono tabular-nums">
                              {money(profit)}{" "}
                              <span className="text-xs text-muted-foreground">
                                ({pct.toFixed(0)}%)
                              </span>
                            </TableCell>
                            <TableCell className="text-center">
                              <Badge variant={tierVariant[row.plan.tier]}>
                                {tierLabel[row.plan.tier][lang]}
                              </Badge>
                            </TableCell>
                            <TableCell className="text-end">
                              <div className="flex justify-end gap-2">
                                <Button
                                  size="sm"
                                  variant="outline"
                                  onClick={() => setPlanFor(row.product_id)}
                                >
                                  {t("off.viewPlan")}
                                </Button>
                                {canManage && (
                                  <Button
                                    size="sm"
                                    onClick={() =>
                                      openNew({
                                        product_id: row.product_id,
                                        label: name(row),
                                        suggested: row.suggested,
                                      })
                                    }
                                  >
                                    {t("off.makeOffer")}
                                  </Button>
                                )}
                              </div>
                            </TableCell>
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* Running offers */}
        <TabsContent value="active" className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle>{t("off.tabActive")}</CardTitle>
            </CardHeader>
            <CardContent>
              {runningOffers.length === 0 ? (
                <EmptyState message={t("off.noOffers")} />
              ) : (
                offerTable(runningOffers)
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* Expired / disabled */}
        <TabsContent value="expired" className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle>{t("off.tabExpired")}</CardTitle>
            </CardHeader>
            <CardContent>
              {pastOffers.length === 0 ? (
                <EmptyState message={t("off.noOffers")} />
              ) : (
                offerTable(pastOffers)
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* Customers & points */}
        <TabsContent value="customers" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-row flex-wrap items-center justify-between gap-3">
              <CardTitle>{t("off.topCustomers")}</CardTitle>
              <Button asChild size="sm" variant="outline">
                <Link to="/loyalty">{t("off.manageLoyalty")}</Link>
              </Button>
            </CardHeader>
            <CardContent>
              <p className="mb-3 text-sm text-muted-foreground">{t("off.customersHint")}</p>
              {(customers.data ?? []).length === 0 ? (
                <EmptyState message={t("off.noData")} />
              ) : (
                <div className="-mx-4 overflow-x-auto px-4">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-start">{t("loy.code")}</TableHead>
                        <TableHead className="text-start">{t("loy.customers")}</TableHead>
                        <TableHead className="text-start">{t("common.phone")}</TableHead>
                        <TableHead className="text-end">{lang === "ar" ? "كاش باك" : "Cashback"}</TableHead>
                        <TableHead className="text-end">{t("loy.spent")}</TableHead>
                        <TableHead className="text-end">{t("loy.visits")}</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {(customers.data ?? []).map((c) => (
                        <TableRow key={c.id} className="odd:bg-muted/30">
                          <TableCell className="text-start font-mono text-xs">{c.code}</TableCell>
                          <TableCell className="text-start font-medium">{c.name}</TableCell>
                          <TableCell className="text-start">{c.phone ?? "—"}</TableCell>
                          <TableCell className="text-end font-mono font-semibold tabular-nums">
                            {money(num(c.wallet_balance))}
                          </TableCell>
                          <TableCell className="text-end font-mono tabular-nums">
                            {money(num(c.total_spent))}
                          </TableCell>
                          <TableCell className="text-end font-mono tabular-nums">
                            {c.visits}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      {/* Offer builder */}
      <Dialog
        open={formOpen}
        onOpenChange={(open) => {
          setFormOpen(open);
          if (!open) resetForm();
        }}
      >
        <DialogContent className="max-h-[92vh] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{editingId ? t("off.editOffer") : t("off.newOffer")}</DialogTitle>
            <DialogDescription>{t("off.safeFloorLabel")}</DialogDescription>
          </DialogHeader>

          <div className="space-y-4">
            <div className="flex gap-2">
              <Button
                type="button"
                className="flex-1"
                variant={mode === "single" ? "default" : "outline"}
                onClick={() => {
                  setMode("single");
                  setPrice("");
                }}
              >
                {t("off.modeSingle")}
              </Button>
              <Button
                type="button"
                className="flex-1"
                variant={mode === "bundle" ? "default" : "outline"}
                onClick={() => {
                  setMode("bundle");
                  setPrice("");
                  if (bundle.length === 0) {
                    setBundle([
                      { product_id: "", quantity: 1 },
                      { product_id: "", quantity: 1 },
                    ]);
                  }
                }}
              >
                {t("off.modeBundle")}
              </Button>
            </div>

            <div className="grid gap-1">
              <Label>{t("off.offerName")}</Label>
              <Input value={title} onChange={(e) => setTitle(e.target.value)} />
            </div>

            {mode === "single" ? (
              <div className="grid gap-1">
                <Label>{t("off.product")}</Label>
                <Select
                  value={productId}
                  onValueChange={(v) => {
                    setProductId(v);
                    setPrice("");
                  }}
                >
                  <SelectTrigger>
                    <SelectValue placeholder={t("off.selectProduct")} />
                  </SelectTrigger>
                  <SelectContent>
                    {(productList.data ?? []).map((p) => (
                      <SelectItem key={p.id} value={p.id}>
                        {name(p)} · {money(num(p.base_price))}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            ) : (
              <div className="space-y-2">
                <Label>{t("off.items")}</Label>
                {bundle.map((row, index) => (
                  <div key={index} className="flex items-center gap-2">
                    <Select
                      value={row.product_id}
                      onValueChange={(v) => {
                        setBundle((prev) =>
                          prev.map((b, i) => (i === index ? { ...b, product_id: v } : b)),
                        );
                        setPrice("");
                      }}
                    >
                      <SelectTrigger className="flex-1">
                        <SelectValue placeholder={t("off.selectProduct")} />
                      </SelectTrigger>
                      <SelectContent>
                        {(productList.data ?? []).map((p) => (
                          <SelectItem key={p.id} value={p.id}>
                            {name(p)} · {money(num(p.base_price))}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                    <Input
                      type="number"
                      min={1}
                      className="w-20 font-mono"
                      value={row.quantity}
                      onChange={(e) => {
                        const q = Math.max(1, Number(e.target.value) || 1);
                        setBundle((prev) =>
                          prev.map((b, i) => (i === index ? { ...b, quantity: q } : b)),
                        );
                        setPrice("");
                      }}
                      aria-label={t("off.qty")}
                    />
                    <Button
                      type="button"
                      size="icon"
                      variant="ghost"
                      className="text-destructive"
                      onClick={() => {
                        setBundle((prev) => prev.filter((_, i) => i !== index));
                        setPrice("");
                      }}
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                ))}
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => setBundle((prev) => [...prev, { product_id: "", quantity: 1 }])}
                >
                  {t("off.addItem")}
                </Button>
              </div>
            )}

            {/* Image */}
            <div className="grid gap-2">
              <Label>{t("off.image")}</Label>
              <div className="flex items-center gap-3">
                {imageUrl ? (
                  <button
                    type="button"
                    onClick={() => setLightbox({ src: imageUrl, alt: title })}
                    className="block"
                  >
                    <img src={imageUrl} alt={title} className="size-16 rounded-md object-cover" />
                  </button>
                ) : (
                  <div className="grid size-16 place-items-center rounded-md bg-muted text-muted-foreground">
                    <Upload className="size-5" />
                  </div>
                )}
                <input
                  ref={fileInput}
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(e) => {
                    const file = e.target.files?.[0];
                    if (file) uploadImage.mutate(file);
                    e.target.value = "";
                  }}
                />
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={uploadImage.isPending}
                  onClick={() => fileInput.current?.click()}
                >
                  {imagePath ? t("off.replaceImage") : t("off.uploadImage")}
                </Button>
                {imagePath && (
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    className="text-destructive"
                    onClick={async () => {
                      await supabase.storage.from("offer-images").remove([imagePath]);
                      setImagePath(null);
                      setImageUrl(null);
                    }}
                  >
                    {t("off.removeImage")}
                  </Button>
                )}
              </div>
            </div>

            {/* Financial advisor */}
            <div className="grid grid-cols-2 gap-3 rounded-lg border bg-muted/30 p-3 text-sm sm:grid-cols-4">
              <div>
                <p className="text-xs text-muted-foreground">{t("off.grossBase")}</p>
                <p className="font-mono font-semibold tabular-nums">{money(base)}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">{t("off.liveCogs")}</p>
                <p className="font-mono font-semibold tabular-nums">{money(cogs)}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">{t("off.normalProfit")}</p>
                <p className="font-mono font-semibold tabular-nums">
                  {money(advisor.data?.normal_profit ?? 0)}{" "}
                  <span className="text-xs text-muted-foreground">
                    ({(advisor.data?.normal_margin ?? 0).toFixed(0)}%)
                  </span>
                </p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">{t("off.floor")}</p>
                <p className="font-mono font-semibold tabular-nums text-primary">
                  {money(safeFloor)}
                </p>
              </div>
            </div>

            <div className="grid gap-1">
              <div className="flex items-center justify-between gap-2">
                <Label>{t("off.offerPrice")}</Label>
                {advisor.data && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="h-7 text-xs"
                    onClick={() =>
                      setPrice(
                        String(
                          suggestPrice(
                            advisor.data!.base_total,
                            advisor.data!.live_cost,
                            advisor.data!.safe_floor,
                          ),
                        ),
                      )
                    }
                  >
                    {lang === "ar" ? "تطبيق السعر المقترح" : "Apply suggested price"} (
                    {money(suggestPrice(advisor.data.base_total, advisor.data.live_cost, advisor.data.safe_floor))})
                  </Button>
                )}
              </div>
              <Input
                type="number"
                step="0.5"
                value={price}
                onChange={(e) => setPrice(e.target.value)}
                className="font-mono"
              />
            </div>

            <div className="grid grid-cols-3 gap-3 rounded-lg border p-3 text-sm">
              <div>
                <p className="text-xs text-muted-foreground">{t("off.customerSaving")}</p>
                <p className="font-mono font-semibold tabular-nums">
                  {money(saving)}{" "}
                  <span className="text-xs text-muted-foreground">
                    ({savingPct.toFixed(0)}%)
                  </span>
                </p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">{t("off.newProfit")}</p>
                <p
                  className={`font-mono font-semibold tabular-nums ${newProfit <= 0 ? "text-destructive" : "text-primary"}`}
                >
                  {money(newProfit)}
                </p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">{t("off.newMargin")}</p>
                <p className="font-mono font-semibold tabular-nums">{newMargin.toFixed(0)}%</p>
              </div>
            </div>

            {advisor.data && offerPrice > 0 ? (
              belowFloor ? (
                <p className="rounded-md bg-destructive/10 p-2 text-xs font-bold text-destructive">
                  {t("off.unsafeBadge")}
                </p>
              ) : (
                <p className="rounded-md bg-primary/10 p-2 text-xs font-bold text-primary">
                  {t("off.safeBadge")} — {money(newProfit)} {t("off.perBundle")}
                </p>
              )
            ) : null}

            <div className="grid grid-cols-2 gap-3">
              <div className="grid gap-1">
                <Label>{t("off.startsAt")}</Label>
                <Input type="date" value={starts} onChange={(e) => setStarts(e.target.value)} />
              </div>
              <div className="grid gap-1">
                <Label>{t("off.endsAt")}</Label>
                <Input type="date" value={ends} onChange={(e) => setEnds(e.target.value)} />
              </div>
            </div>
            <div className="grid gap-1">
              <Label>{t("off.notes")}</Label>
              <Input value={notes} onChange={(e) => setNotes(e.target.value)} />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setFormOpen(false)}>
              {t("common.cancel")}
            </Button>
            <Button
              onClick={() => save.mutate()}
              disabled={save.isPending || !canManage || belowFloor || !title.trim()}
            >
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Plan dialog */}
      <Dialog open={Boolean(planFor)} onOpenChange={(open) => !open && setPlanFor(null)}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>{active ? name(active) : ""}</DialogTitle>
            <DialogDescription>{active?.plan.headline}</DialogDescription>
          </DialogHeader>
          {active && (
            <div className="space-y-3 text-sm">
              <ul className="space-y-2">
                {active.plan.steps.map((step, i) => (
                  <li key={i} className="rounded-md border bg-muted/30 p-2">
                    {step}
                  </li>
                ))}
              </ul>
              <p className="rounded-md bg-primary/10 p-2 text-xs">{active.plan.guard}</p>
              {canManage && (
                <Button
                  className="w-full"
                  onClick={() => {
                    setPlanFor(null);
                    openNew({
                      product_id: active.product_id,
                      label: name(active),
                      suggested: active.suggested,
                    });
                  }}
                >
                  {t("off.makeOfferAt")} {money(active.suggested)}
                </Button>
              )}
            </div>
          )}
        </DialogContent>
      </Dialog>

      {/* High-res lightbox */}
      {lightbox ? (
        <div
          role="presentation"
          onClick={() => setLightbox(null)}
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4"
        >
          <Button
            type="button"
            size="icon"
            variant="secondary"
            aria-label={t("common.close")}
            className="absolute end-4 top-4"
            onClick={(e) => {
              e.stopPropagation();
              setLightbox(null);
            }}
          >
            <X className="size-4" />
          </Button>
          <img
            src={lightbox.src}
            alt={lightbox.alt}
            className="max-h-full max-w-full rounded-lg object-contain"
          />
        </div>
      ) : null}
    </div>
  );
}
