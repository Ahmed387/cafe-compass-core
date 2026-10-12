import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Trash2 } from "lucide-react";

import { useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { ImageThumb } from "@/components/shared";
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { useProductImageUrls } from "@/lib/product-images";
import { ProductStudioDialog, type StudioProduct } from "@/components/menu/ProductStudioDialog";

export const Route = createFileRoute("/_authenticated/menu-studio")({
  head: () => ({
    meta: [
      { title: "Menu & products — 20s Coffee" },
      {
        name: "description",
        content: "Manage categories, drinks, sizes and add-ons for the 20s Coffee menu.",
      },
      { property: "og:title", content: "Menu & products — 20s Coffee" },
      {
        property: "og:description",
        content: "Categories, products, sizes and modifiers in one place.",
      },
    ],
  }),
  component: MenuPage,
});

function MenuPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const canViewCost = can("products.view_cost");
  const queryClient = useQueryClient();
  // Rule 5: catalog mutations belong to the owner only; managers read the menu.
  const isSuperAdmin = me?.roleNames.includes("Super Admin") ?? false;
  const canEdit = isSuperAdmin && (can("products.update") || can("products.create"));
  const canManageModifiers = canEdit;

  const [studioOpen, setStudioOpen] = useState(false);
  const [studioProduct, setStudioProduct] = useState<StudioProduct | null>(null);
  const [sizeProduct, setSizeProduct] = useState<{ id: string; name: string } | null>(null);
  const [sizeForm, setSizeForm] = useState({ name: "", name_ar: "", price_delta: "" });
  const [productToDelete, setProductToDelete] = useState<{ id: string; name: string } | null>(null);

  const products = useQuery({
    queryKey: ["products"],
    enabled: can("products.view"),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("products")
        .select(
          "id, name, name_ar, base_price, image_url, is_available, is_active, show_on_public_menu, category_id, categories(name, name_ar), product_sizes(id, name, name_ar, price_delta)",
        )
        .eq("is_active", true)
        .order("display_order");

      if (error) throw error;
      return data ?? [];
    },
  });

  const label = (row: { name: string; name_ar: string | null }) =>
    lang === "ar" ? row.name_ar || row.name : row.name;
  const tr = (arText: string, enText: string) => (lang === "ar" ? arText : enText);

  // Which products already have a stock recipe — drives the status badge and the visibility toggle.
  const recipeLinks = useQuery({
    queryKey: ["product-recipe-links"],
    enabled: can("products.view"),
    queryFn: async () => {
      const { data, error } = await supabase.from("product_recipes").select("product_id");
      if (error) throw error;
      return new Set((data ?? []).map((row) => row.product_id));
    },
  });
  const hasRecipe = (id: string) => recipeLinks.data?.has(id) ?? false;

  const togglePublicMenu = useMutation({
    mutationFn: async (product: { id: string; show_on_public_menu: boolean }) => {
      const next = !product.show_on_public_menu;
      const { error } = await supabase
        .from("products")
        .update({ show_on_public_menu: next })
        .eq("id", product.id);
      if (error) throw error;
      await supabase.rpc("log_audit", {
        _action: next ? "product.show_on_public_menu" : "product.hide_from_public_menu",
        _module: "products",
        _entity_type: "products",
        _entity_id: product.id,
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["public-menu"] });
      toast.success(tr("تم تحديث الظهور في منيو الزبون.", "Public menu visibility updated."));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const imageUrls = useProductImageUrls((products.data ?? []).map((p) => p.image_url));
  const imageOf = (path: string | null) => (path ? (imageUrls.data?.get(path) ?? null) : null);

  // Cost is protected at the database level; only permitted roles can read it.
  const productCosts = useQuery({
    queryKey: ["product-costs"],
    enabled: canViewCost,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("product_costs");
      if (error) throw error;
      const map = new Map<string, number>();
      for (const row of data ?? []) map.set(row.product_id, Number(row.cost));
      return map;
    },
  });
  const costOf = (id: string) => productCosts.data?.get(id) ?? 0;

  const archiveProduct = useMutation({
    mutationFn: async (id: string) => {
      const { data, error } = await supabase.rpc("delete_product_hard", { _product_id: id });
      if (error) throw error;
      return data as unknown as { mode: string };
    },
    onSuccess: (result) => {
      setProductToDelete(null);
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["pos-products"] });
      toast.success(
        result?.mode === "deactivated"
          ? tr(
              "المنتج مستخدم في فواتير سابقة، فتم تعطيله بدل حذفه للحفاظ على الفواتير.",
              "This product is used on past invoices, so it was disabled instead of deleted.",
            )
          : tr("تم حذف المنتج نهائياً.", "Product permanently deleted."),
      );
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const toggleProduct = useMutation({
    mutationFn: async (product: { id: string; is_available: boolean }) => {
      const { error } = await supabase
        .from("products")
        .update({ is_available: !product.is_available })
        .eq("id", product.id);
      if (error) throw error;
      await supabase.rpc("log_audit", {
        _action: product.is_available ? "product.mark_unavailable" : "product.mark_available",
        _module: "products",
        _entity_type: "products",
        _entity_id: product.id,
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["pos-products"] });
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const addSize = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from("product_sizes").insert({
        product_id: sizeProduct!.id,
        name: sizeForm.name,
        name_ar: sizeForm.name_ar || null,
        price_delta: Number(sizeForm.price_delta || 0),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setSizeForm({ name: "", name_ar: "", price_delta: "" });
      setSizeProduct(null);
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["pos-products"] });
      toast.success(lang === "ar" ? "تم إضافة الحجم." : "Size added.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!can("products.view")) return <NoPermission message={t("common.noAccess")} />;

  return (
    <div>
      <PageHeader
        title={t("menu.title")}
        action={
          canEdit && (
            <Button
              onClick={() => {
                setStudioProduct(null);
                setStudioOpen(true);
              }}
            >
              + {t("menu.newProduct")}
            </Button>
          )
        }
      />

      <div className="mt-4 space-y-4">
        <div className="grid gap-3 sm:grid-cols-3">
          {[
            {
              icon: "📦",
              label: tr("إجمالي الأصناف النشطة", "Active products"),
              value: (products.data ?? []).length,
              tone: "text-foreground",
            },
            {
              icon: "⚠️",
              label: tr("أصناف بحاجة لوصفة", "Products needing a recipe"),
              value: (products.data ?? []).filter((p) => !hasRecipe(p.id)).length,
              tone: "text-rose-600 dark:text-rose-400",
            },
            {
              icon: "🌐",
              label: tr("المعروض في منيو الـ QR", "Visible on QR menu"),
              value: (products.data ?? []).filter((p) => p.show_on_public_menu).length,
              tone: "text-emerald-600 dark:text-emerald-400",
            },
          ].map((metric) => (
            <div key={metric.label} className="card-surface rounded-xl border border-border bg-card p-4">
              <p className="text-sm text-muted-foreground">
                {metric.icon} {metric.label}
              </p>
              <p className={`mt-1 text-2xl font-bold tabular-nums ${metric.tone}`}>
                {metric.value}
              </p>
            </div>
          ))}
        </div>

        {!products.data || products.data.length === 0 ? (
          <EmptyState message={t("menu.emptyProducts")} />
        ) : (
          <div className="overflow-x-auto rounded-lg border border-border bg-card">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-14"></TableHead>
                  <TableHead>{t("common.name")}</TableHead>
                  <TableHead>{t("menu.category")}</TableHead>
                  <TableHead>{t("menu.price")}</TableHead>
                  {canViewCost && <TableHead>{t("menu.cost")}</TableHead>}
                  <TableHead>{t("menu.sizes")}</TableHead>
                  <TableHead>{tr("حالة الوصفة", "Recipe status")}</TableHead>
                  <TableHead>{tr("الظهور للزبون", "Public visibility")}</TableHead>
                  <TableHead>{t("common.status")}</TableHead>
                  {canEdit && <TableHead>{t("common.actions")}</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {products.data.map((product) => (
                  <TableRow key={product.id}>
                    <TableCell>
                      <ImageThumb src={imageOf(product.image_url)} alt={label(product)} />
                    </TableCell>
                    <TableCell className="font-medium">{label(product)}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {product.categories ? label(product.categories) : "—"}
                    </TableCell>
                    <TableCell>{formatMoney(Number(product.base_price), "EGP", lang)}</TableCell>
                    {canViewCost && (
                      <TableCell className="text-muted-foreground">
                        {formatMoney(costOf(product.id), "EGP", lang)}
                      </TableCell>
                    )}
                    <TableCell className="text-muted-foreground">
                      {product.product_sizes.length
                        ? product.product_sizes
                            .map((size) => `${label(size)} (+${Number(size.price_delta)})`)
                            .join(", ")
                        : "—"}
                    </TableCell>
                    <TableCell>
                      {hasRecipe(product.id) ? (
                        <span className="inline-flex items-center gap-1 rounded-full border border-emerald-500/30 bg-emerald-500/12 px-2.5 py-0.5 text-xs font-semibold text-emerald-700 dark:text-emerald-300">
                          {tr("له وصفة ✅", "Has recipe ✅")}
                        </span>
                      ) : (
                        <button
                          type="button"
                          title={tr(
                            "اضغط لإضافة وصفة مخزنية لهذا المنتج",
                            "Click to add a stock recipe for this product",
                          )}
                          onClick={() => {
                            setStudioProduct({
                              id: product.id,
                              name: product.name,
                              name_ar: product.name_ar,
                              base_price: product.base_price,
                              category_id: product.category_id,
                              image_url: product.image_url,
                            });
                            setStudioOpen(true);
                          }}
                          className="inline-flex items-center gap-1 rounded-full border border-rose-500/30 bg-rose-500/12 px-2.5 py-0.5 text-xs font-semibold text-rose-700 transition-all duration-200 hover:bg-rose-500/20 dark:text-rose-300"
                        >
                          {tr("بلا وصفة ❌", "No recipe ❌")}
                        </button>
                      )}
                    </TableCell>
                    <TableCell>
                      <span
                        title={
                          !hasRecipe(product.id)
                            ? tr(
                                "لا يمكن عرض هذا المنتج للزبون قبل إضافة وصفة مخزنية له",
                                "This product cannot be shown to guests before adding a stock recipe",
                              )
                            : undefined
                        }
                        className="inline-flex"
                      >
                        <Switch
                          checked={product.show_on_public_menu && hasRecipe(product.id)}
                          disabled={!isSuperAdmin || !hasRecipe(product.id)}
                          aria-label={tr("الظهور للزبون", "Public visibility")}
                          onCheckedChange={() =>
                            togglePublicMenu.mutate({
                              id: product.id,
                              show_on_public_menu: product.show_on_public_menu,
                            })
                          }
                        />
                      </span>
                    </TableCell>
                    <TableCell>
                      <Badge variant={product.is_available ? "secondary" : "outline"}>
                        {product.is_available ? t("menu.available") : t("menu.unavailable")}
                      </Badge>
                    </TableCell>
                    {canEdit && (
                      <TableCell className="space-x-2 whitespace-nowrap">
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => {
                            setStudioProduct({
                              id: product.id,
                              name: product.name,
                              name_ar: product.name_ar,
                              base_price: product.base_price,
                              category_id: product.category_id,
                              image_url: product.image_url,
                            });
                            setStudioOpen(true);
                          }}
                        >
                          {t("common.edit")}
                        </Button>
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setSizeProduct({ id: product.id, name: label(product) })}
                        >
                          {t("menu.addSize")}
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() =>
                            toggleProduct.mutate({
                              id: product.id,
                              is_available: product.is_available,
                            })
                          }
                        >
                          {product.is_available ? t("common.disable") : t("common.enable")}
                        </Button>
                        {isSuperAdmin && (
                          <Button
                            size="sm"
                            variant="ghost"
                            className="text-destructive hover:text-destructive"
                            aria-label={t("common.delete")}
                            onClick={() =>
                              setProductToDelete({ id: product.id, name: label(product) })
                            }
                          >
                            <Trash2 className="size-4" />
                          </Button>
                        )}
                      </TableCell>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </div>

      <ProductStudioDialog
        open={studioOpen}
        onOpenChange={setStudioOpen}
        product={studioProduct}
        companyId={me!.profile.company_id}
        currency={me?.company?.currency ?? "EGP"}
      />

      <Dialog open={sizeProduct !== null} onOpenChange={(open) => !open && setSizeProduct(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {t("menu.addSize")} — {sizeProduct?.name}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label>{t("menu.nameEn")}</Label>
              <Input
                value={sizeForm.name}
                onChange={(event) => setSizeForm({ ...sizeForm, name: event.target.value })}
              />
            </div>
            <div className="space-y-2">
              <Label>{t("menu.nameAr")}</Label>
              <Input
                value={sizeForm.name_ar}
                onChange={(event) => setSizeForm({ ...sizeForm, name_ar: event.target.value })}
              />
            </div>
            <div className="space-y-2">
              <Label>{t("menu.priceDelta")}</Label>
              <Input
                type="number"
                step="0.01"
                value={sizeForm.price_delta}
                onChange={(event) => setSizeForm({ ...sizeForm, price_delta: event.target.value })}
              />
            </div>
          </div>
          <DialogFooter>
            <Button onClick={() => addSize.mutate()} disabled={!sizeForm.name || addSize.isPending}>
              {t("common.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={productToDelete !== null}
        onOpenChange={(open) => !open && setProductToDelete(null)}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {tr(
                `هل أنت متأكد من حذف المنتج ${productToDelete?.name ?? ""}؟`,
                `Delete the product ${productToDelete?.name ?? ""}?`,
              )}
            </DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            {tr(
              "سيتم إخفاء المنتج من المنيو ونقاط البيع ومنيو الـQR، ويبقى محفوظًا في الفواتير والتقارير السابقة.",
              "The product is hidden from the menu, POS and QR menu, and stays intact on past invoices and reports.",
            )}
          </p>
          <DialogFooter>
            <Button variant="outline" onClick={() => setProductToDelete(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={archiveProduct.isPending}
              onClick={() => productToDelete && archiveProduct.mutate(productToDelete.id)}
            >
              {t("common.delete")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
