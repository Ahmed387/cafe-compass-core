import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, ChevronsUpDown, Plus, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
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
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { MAX_PRODUCT_IMAGE_BYTES, uploadProductImage } from "@/lib/product-images";

export type StudioProduct = {
  id: string;
  name: string;
  name_ar: string | null;
  base_price: number | string | null;
  category_id: string | null;
  image_url: string | null;
};

type Named = { name: string; name_ar: string | null };

type InventoryItem = Named & {
  id: string;
  unit: string;
  cost_per_unit: number | string | null;
};

type RecipeRow = { key: string; item_id: string; quantity: string };

type StudioOption = {
  key: string;
  id?: string;
  name: string;
  name_ar: string;
  price_delta: string;
  item_id: string;
  quantity: string;
};

type StudioGroup = {
  key: string;
  id?: string;
  name: string;
  name_ar: string;
  min_select: string;
  max_select: string;
  options: StudioOption[];
};

const uid = () => Math.random().toString(36).slice(2);
const newRecipeRow = (): RecipeRow => ({ key: uid(), item_id: "", quantity: "" });
const newOption = (): StudioOption => ({
  key: uid(),
  name: "",
  name_ar: "",
  price_delta: "0",
  item_id: "",
  quantity: "",
});

function RawMaterialCombobox({
  items,
  value,
  onValueChange,
  onSelected,
  lang,
  currency,
  emptyLabel,
}: {
  items: InventoryItem[];
  value: string;
  onValueChange: (value: string) => void;
  onSelected: () => void;
  lang: "en" | "ar";
  currency: string;
  emptyLabel: string;
}) {
  const [open, setOpen] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const selected = items.find((item) => item.id === value);
  const itemLabel = (item: InventoryItem) =>
    (lang === "ar" ? item.name_ar || item.name : item.name || item.name_ar) ?? "—";

  const selectItem = (itemId: string) => {
    onValueChange(itemId);
    setOpen(false);
    window.requestAnimationFrame(onSelected);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          role="combobox"
          aria-expanded={open}
          className="mt-1 w-full justify-between gap-2 px-3 font-normal"
        >
          <span className="truncate text-start">{selected ? itemLabel(selected) : emptyLabel}</span>
          <ChevronsUpDown className="size-4 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent
        className="w-[min(24rem,var(--radix-popover-trigger-width))] min-w-[var(--radix-popover-trigger-width)] p-0"
        align="start"
        onOpenAutoFocus={(event) => {
          event.preventDefault();
          inputRef.current?.focus();
        }}
      >
        <Command>
          <CommandInput
            ref={inputRef}
            placeholder={lang === "ar" ? "بحث عن خامة..." : "Search raw materials..."}
          />
          <CommandList>
            <CommandEmpty>
              {lang === "ar" ? "لا توجد خامة مطابقة" : "No matching raw material"}
            </CommandEmpty>
            <CommandGroup>
              {items.map((item) => (
                <CommandItem
                  key={item.id}
                  value={`${item.name} ${item.name_ar ?? ""} ${item.unit}`}
                  onSelect={() => selectItem(item.id)}
                  className="items-start py-2"
                >
                  <Check
                    className={`mt-0.5 size-4 ${value === item.id ? "opacity-100" : "opacity-0"}`}
                  />
                  <span className="min-w-0 flex-1 text-start">
                    <span className="block truncate font-medium">{itemLabel(item)}</span>
                    {item.name_ar && item.name_ar !== item.name && (
                      <span className="block truncate text-xs text-muted-foreground">
                        {lang === "ar" ? item.name : item.name_ar}
                      </span>
                    )}
                  </span>
                  <span className="flex shrink-0 items-center gap-1.5">
                    <Badge variant="outline" className="font-mono text-[10px]">
                      {item.unit}
                    </Badge>
                    <span className="text-xs text-muted-foreground tabular-nums">
                      {formatMoney(item.cost_per_unit, currency, lang)} / {item.unit}
                    </span>
                  </span>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}

export function ProductStudioDialog({
  open,
  onOpenChange,
  product,
  companyId,
  currency,
  onSaved,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  product: StudioProduct | null;
  companyId: string;
  currency: string;
  onSaved?: () => void;
}) {
  const { lang } = useI18n();
  const queryClient = useQueryClient();
  const tr = (ar: string, en: string) => (lang === "ar" ? ar : en);
  const label = (row: Named | null | undefined) =>
    (lang === "ar" ? row?.name_ar || row?.name : row?.name) ?? "—";

  const [name, setName] = useState("");
  const [nameAr, setNameAr] = useState("");
  const [price, setPrice] = useState("");
  const [categoryId, setCategoryId] = useState("");
  const [newCategory, setNewCategory] = useState("");
  const [categoryOpen, setCategoryOpen] = useState(false);
  const [categoryQuery, setCategoryQuery] = useState("");
  const [imageFile, setImageFile] = useState<File | null>(null);
  const [imagePreview, setImagePreview] = useState<string | null>(null);
  const [imagePath, setImagePath] = useState<string | null>(null);
  const [rows, setRows] = useState<RecipeRow[]>([newRecipeRow()]);
  const [groups, setGroups] = useState<StudioGroup[]>([]);
  const [addGroupOpen, setAddGroupOpen] = useState(false);
  const quantityRefs = useRef<Record<string, HTMLInputElement | null>>({});

  const categories = useQuery({
    queryKey: ["studio-categories"],
    enabled: open,
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

  const items = useQuery({
    queryKey: ["studio-inventory"],
    enabled: open,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("inventory_items")
        .select("id, name, name_ar, unit, cost_per_unit")
        .eq("is_active", true)
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const library = useQuery({
    queryKey: ["studio-modifier-library"],
    enabled: open,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("modifier_groups")
        .select(
          "id, name, name_ar, min_select, max_select, modifier_options(id, name, name_ar, price_delta, is_active, modifier_option_recipes(item_id, quantity))",
        )
        .eq("is_active", true)
        .order("display_order");
      if (error) throw error;
      return data ?? [];
    },
  });

  const productRecipe = useQuery({
    queryKey: ["studio-recipe", product?.id],
    enabled: open && Boolean(product?.id),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("product_recipes")
        .select("item_id, quantity")
        .eq("product_id", product!.id);
      if (error) throw error;
      return data ?? [];
    },
  });

  const productGroups = useQuery({
    queryKey: ["studio-product-groups", product?.id],
    enabled: open && Boolean(product?.id),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("product_modifier_groups")
        .select("group_id")
        .eq("product_id", product!.id);
      if (error) throw error;
      return (data ?? []).map((row) => row.group_id);
    },
  });

  const libraryGroup = (groupId: string) => (library.data ?? []).find((g) => g.id === groupId);

  const groupFromLibrary = (groupId: string): StudioGroup | null => {
    const source = libraryGroup(groupId);
    if (!source) return null;
    return {
      key: uid(),
      id: source.id,
      name: source.name,
      name_ar: source.name_ar ?? "",
      min_select: String(source.min_select ?? 0),
      max_select: String(source.max_select ?? 1),
      options: (source.modifier_options ?? [])
        .filter((option) => option.is_active)
        .map((option) => {
          const recipe = option.modifier_option_recipes?.[0];
          return {
            key: uid(),
            id: option.id,
            name: option.name,
            name_ar: option.name_ar ?? "",
            price_delta: String(Number(option.price_delta ?? 0)),
            item_id: recipe?.item_id ?? "",
            quantity: recipe ? String(Number(recipe.quantity)) : "",
          };
        }),
    };
  };

  // Loads the product's current definition once everything it needs is in cache.
  const ready =
    open &&
    !items.isLoading &&
    !library.isLoading &&
    (!product?.id || (!productRecipe.isLoading && !productGroups.isLoading));

  useEffect(() => {
    if (!open) return;
    setName(product?.name ?? "");
    setNameAr(product?.name_ar ?? "");
    setPrice(product ? String(Number(product.base_price ?? 0)) : "");
    setCategoryId(product?.category_id ?? "");
    setNewCategory("");
    setCategoryQuery("");
    setImageFile(null);
    setImagePreview(null);
    setImagePath(product?.image_url ?? null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, product?.id]);

  // Hydrate recipe/add-on drafts exactly once per open session, so background
  // refetches (e.g. returning to the browser tab) never overwrite unsaved edits.
  const hydratedKey = useRef<string | null>(null);
  useEffect(() => {
    if (!open) hydratedKey.current = null;
  }, [open]);

  useEffect(() => {
    if (!ready) return;
    const key = product?.id ?? "__new__";
    if (hydratedKey.current === key) return;
    hydratedKey.current = key;
    const recipeRows = (productRecipe.data ?? []).map((row) => ({
      key: uid(),
      item_id: row.item_id,
      quantity: String(Number(row.quantity)),
    }));
    setRows(recipeRows.length > 0 ? recipeRows : [newRecipeRow()]);
    const linked = (productGroups.data ?? [])
      .map((id) => groupFromLibrary(id))
      .filter((group): group is StudioGroup => group !== null);
    setGroups(linked);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, product?.id, productRecipe.data, productGroups.data, library.data]);

  const itemOf = (itemId: string) => (items.data ?? []).find((row) => row.id === itemId);
  const unitCost = (itemId: string) => Number(itemOf(itemId)?.cost_per_unit ?? 0);
  const unitOf = (itemId: string) => itemOf(itemId)?.unit ?? "";
  const lineCost = (itemId: string, quantity: string) => {
    const qty = Number(quantity);
    return Number.isFinite(qty) ? qty * unitCost(itemId) : 0;
  };

  const recipeCost = useMemo(
    () => rows.reduce((sum, row) => sum + lineCost(row.item_id, row.quantity), 0),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [rows, items.data],
  );

  const sellPrice = Number(price || 0);
  const margin = sellPrice - recipeCost;
  const marginPercent = sellPrice > 0 ? (margin / sellPrice) * 100 : 0;
  const marginTone =
    sellPrice <= 0
      ? "bg-muted text-muted-foreground"
      : marginPercent >= 50
        ? "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
        : margin <= 0
          ? "bg-destructive/15 text-destructive"
          : "bg-amber-500/15 text-amber-600 dark:text-amber-500";

  const patchRow = (key: string, next: Partial<RecipeRow>) =>
    setRows((prev) => prev.map((row) => (row.key === key ? { ...row, ...next } : row)));
  const addRow = () => setRows((prev) => [...prev, newRecipeRow()]);
  const removeRow = (key: string) =>
    setRows((prev) => {
      const next = prev.filter((row) => row.key !== key);
      return next.length > 0 ? next : [newRecipeRow()];
    });

  const patchGroup = (key: string, next: Partial<StudioGroup>) =>
    setGroups((prev) => prev.map((group) => (group.key === key ? { ...group, ...next } : group)));
  const patchOption = (groupKey: string, optionKey: string, next: Partial<StudioOption>) =>
    setGroups((prev) =>
      prev.map((group) =>
        group.key === groupKey
          ? {
              ...group,
              options: group.options.map((option) =>
                option.key === optionKey ? { ...option, ...next } : option,
              ),
            }
          : group,
      ),
    );

  const usedGroupIds = groups.map((group) => group.id).filter(Boolean) as string[];
  const availableGroups = (library.data ?? []).filter((group) => !usedGroupIds.includes(group.id));
  const categoryTerm = categoryQuery.trim().toLowerCase();
  const filteredCategories = (categories.data ?? []).filter(
    (row) =>
      !categoryTerm ||
      row.name.toLowerCase().includes(categoryTerm) ||
      (row.name_ar ?? "").toLowerCase().includes(categoryTerm),
  );
  const selectedCategory = (categories.data ?? []).find((row) => row.id === categoryId) ?? null;
  const categoryLabel = newCategory
    ? `${newCategory} (${tr("جديد", "new")})`
    : selectedCategory
      ? label(selectedCategory)
      : tr("اختر التصنيف", "Select category");

  const save = useMutation({
    mutationFn: async () => {
      if (!name.trim() && !nameAr.trim())
        throw new Error(tr("اسم المنتج مطلوب.", "Product name is required."));
      let storedImage = imagePath;
      if (imageFile) storedImage = await uploadProductImage(imageFile, companyId);

      const payload = {
        ...(product?.id ? { id: product.id } : {}),
        name: name.trim() || nameAr.trim(),
        name_ar: nameAr.trim() || null,
        category_id: newCategory ? null : categoryId || null,
        ...(newCategory ? { new_category: newCategory, new_category_ar: newCategory } : {}),
        base_price: Number(price || 0),
        image_url: storedImage,
        recipe: rows
          .filter((row) => row.item_id && Number(row.quantity) > 0)
          .map((row) => ({ item_id: row.item_id, quantity: Number(row.quantity) })),
        modifier_groups: groups.map((group) => ({
          ...(group.id ? { id: group.id } : {}),
          name: group.name.trim() || group.name_ar.trim(),
          name_ar: group.name_ar.trim() || null,
          min_select: Number(group.min_select || 0),
          max_select: Number(group.max_select || 1),
          options: group.options
            .filter((option) => option.name.trim() || option.name_ar.trim())
            .map((option) => ({
              ...(option.id ? { id: option.id } : {}),
              name: option.name.trim() || option.name_ar.trim(),
              name_ar: option.name_ar.trim() || null,
              price_delta: Number(option.price_delta || 0),
              item_id: option.item_id || null,
              quantity: Number(option.quantity || 0),
            })),
        })),
      };

      const { error } = await supabase.rpc("save_product_studio", { _payload: payload });
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success(
        tr(
          "تم حفظ المنتج والوصفة والإضافات بنجاح",
          "Product, recipe and add-ons saved successfully",
        ),
      );
      await Promise.all(
        [
          "products",
          "product-costs",
          "product-recipe-links",
          "categories",
          "studio-categories",
          "modifier-groups",
          "studio-modifier-library",
          "product-modifier-links",
          "pos-products",
          "pos-categories",
          "pos-modifiers",
          "recipes",
          "modifier-recipes",
          "public-menu",
        ].map((key) => queryClient.invalidateQueries({ queryKey: [key] })),
      );
      onSaved?.();
      onOpenChange(false);
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92vh] max-w-4xl overflow-y-auto scrollbar-thin">
        <DialogHeader>
          <DialogTitle>{tr("استوديو المنتج الموحّد", "All-in-one product studio")}</DialogTitle>
          <DialogDescription>
            {tr(
              "المنتج والتصنيف والوصفة والتكلفة والتسعير والإضافات في شاشة واحدة.",
              "Product, category, recipe, cost, pricing and add-ons in one screen.",
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-6">
          {/* A — basics */}
          <section className="space-y-3 rounded-xl border border-border p-4">
            <h3 className="text-sm font-semibold">
              {tr("الأساسيات والتصنيف", "Basics & category")}
            </h3>
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label>{tr("الاسم بالعربي", "Arabic name")}</Label>
                <Input
                  className="mt-1"
                  value={nameAr}
                  onChange={(event) => setNameAr(event.target.value)}
                />
              </div>
              <div>
                <Label>{tr("الاسم بالإنجليزي", "English name")}</Label>
                <Input
                  className="mt-1 text-start"
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                />
              </div>
            </div>

            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label>{tr("التصنيف", "Category")}</Label>
                <Popover open={categoryOpen} onOpenChange={setCategoryOpen}>
                  <PopoverTrigger asChild>
                    <Button
                      variant="outline"
                      role="combobox"
                      className="mt-1 w-full justify-between gap-2 font-normal"
                    >
                      <span className="truncate text-start">{categoryLabel}</span>
                      <ChevronsUpDown className="size-4 shrink-0 opacity-50" />
                    </Button>
                  </PopoverTrigger>
                  <PopoverContent className="w-[20rem] p-0" align="start">
                    <Command shouldFilter={false}>
                      <CommandInput
                        placeholder={tr("ابحث عن تصنيف…", "Search category…")}
                        value={categoryQuery}
                        onValueChange={setCategoryQuery}
                      />
                      <CommandList>
                        {filteredCategories.length === 0 && !categoryTerm ? (
                          <CommandEmpty>{tr("لا توجد تصنيفات.", "No categories.")}</CommandEmpty>
                        ) : null}
                        <CommandGroup>
                          {filteredCategories.map((row) => (
                            <CommandItem
                              key={row.id}
                              value={row.id}
                              onSelect={() => {
                                setCategoryId(row.id);
                                setNewCategory("");
                                setCategoryOpen(false);
                              }}
                            >
                              <Check
                                className={`size-4 ${categoryId === row.id && !newCategory ? "opacity-100" : "opacity-0"}`}
                              />
                              <span className="text-start">{label(row)}</span>
                            </CommandItem>
                          ))}
                        </CommandGroup>
                        {categoryTerm && (
                          <CommandGroup>
                            <CommandItem
                              value={`__new__${categoryTerm}`}
                              className="text-primary"
                              onSelect={() => {
                                setNewCategory(categoryQuery.trim());
                                setCategoryId("");
                                setCategoryOpen(false);
                              }}
                            >
                              <Plus className="size-4" />
                              <span className="text-start">
                                {tr("+ تصنيف جديد: ", "+ New category: ")}
                                {categoryQuery.trim()}
                              </span>
                            </CommandItem>
                          </CommandGroup>
                        )}
                      </CommandList>
                    </Command>
                  </PopoverContent>
                </Popover>
              </div>

              <div>
                <Label>{tr("صورة المنتج", "Product image")}</Label>
                <div className="mt-1 flex items-center gap-3">
                  <div className="size-14 shrink-0 overflow-hidden rounded-lg border border-border bg-muted">
                    {imagePreview ? (
                      <img src={imagePreview} alt="" className="size-full object-cover" />
                    ) : null}
                  </div>
                  <Input
                    type="file"
                    accept="image/png,image/jpeg,image/webp"
                    onChange={(event) => {
                      const file = event.target.files?.[0] ?? null;
                      if (!file) return;
                      if (file.size > MAX_PRODUCT_IMAGE_BYTES) {
                        toast.error(tr("الصورة كبيرة جداً.", "Image is too large."));
                        return;
                      }
                      setImageFile(file);
                      setImagePreview(URL.createObjectURL(file));
                    }}
                  />
                </div>
              </div>
            </div>
          </section>

          {/* B — recipe */}
          <section className="space-y-3 rounded-xl border border-border p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-sm font-semibold">
                {tr("مكونات الوصفة وتكلفة الإنتاج", "Recipe & production cost")}
              </h3>
              <Badge variant="secondary" className="tabular-nums">
                {tr("إجمالي تكلفة المكونات: ", "Total recipe cost: ")}
                {formatMoney(recipeCost, currency, lang)}
              </Badge>
            </div>

            <div className="space-y-2">
              {rows.map((row) => (
                <div key={row.key} className="grid items-end gap-2 sm:grid-cols-[2fr_1fr_1fr_auto]">
                  <div>
                    <Label className="text-xs">{tr("الخامة", "Raw material")}</Label>
                    <RawMaterialCombobox
                      items={items.data ?? []}
                      value={row.item_id}
                      onValueChange={(next) => patchRow(row.key, { item_id: next })}
                      onSelected={() => quantityRefs.current[`recipe-${row.key}`]?.focus()}
                      lang={lang}
                      currency={currency}
                      emptyLabel={tr("اختر خامة", "Select material")}
                    />
                  </div>
                  <div>
                    <Label className="text-xs">{tr("الكمية", "Qty")}</Label>
                    <div className="mt-1 flex items-center gap-1">
                      <Input
                        ref={(node) => {
                          quantityRefs.current[`recipe-${row.key}`] = node;
                        }}
                        inputMode="decimal"
                        className="text-end tabular-nums"
                        value={row.quantity}
                        onChange={(event) => patchRow(row.key, { quantity: event.target.value })}
                        onKeyDown={(event) => {
                          if (event.key === "Enter") {
                            event.preventDefault();
                            addRow();
                          }
                        }}
                      />
                      {row.item_id && (
                        <Badge variant="outline" className="shrink-0">
                          {unitOf(row.item_id)}
                        </Badge>
                      )}
                    </div>
                  </div>
                  <div>
                    <Label className="text-xs">{tr("تكلفة الخامة", "Cost")}</Label>
                    <div className="mt-1 rounded-md border border-border bg-muted px-3 py-2 text-sm tabular-nums">
                      {formatMoney(lineCost(row.item_id, row.quantity), currency, lang)}
                    </div>
                  </div>
                  <Button
                    size="icon"
                    variant="ghost"
                    className="text-destructive"
                    aria-label={tr("حذف", "Remove")}
                    onClick={() => removeRow(row.key)}
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              ))}
            </div>

            <Button size="sm" variant="outline" onClick={addRow}>
              <Plus className="me-1 size-4" />
              {tr("إضافة مكوّن آخر", "Add ingredient")}
            </Button>
          </section>

          {/* C — pricing */}
          <section className="space-y-3 rounded-xl border border-border p-4">
            <h3 className="text-sm font-semibold">
              {tr("التسعير وهامش الربح", "Pricing & profit margin")}
            </h3>
            <div className="grid items-end gap-3 sm:grid-cols-2">
              <div>
                <Label>{tr("سعر البيع للزبون", "Selling price")}</Label>
                <Input
                  inputMode="decimal"
                  className="mt-1 h-11 text-end text-lg font-semibold tabular-nums"
                  value={price}
                  onChange={(event) => setPrice(event.target.value)}
                />
              </div>
              <div className={`rounded-xl px-4 py-3 ${marginTone}`}>
                <div className="text-sm font-semibold tabular-nums">
                  {tr("صافي الربح التقديري: ", "Estimated net margin: ")}
                  {formatMoney(margin, currency, lang)}
                </div>
                <div className="text-xs tabular-nums">
                  {tr("نسبة الربح: ", "Margin: ")}
                  {marginPercent.toFixed(1)}%
                </div>
              </div>
            </div>
          </section>

          {/* D — modifiers */}
          <section className="space-y-3 rounded-xl border border-border p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-sm font-semibold">
                {tr("الإضافات وخاماتها وتسعيرها", "Add-ons, stock & pricing")}
              </h3>
              <div className="flex gap-2">
                <Popover open={addGroupOpen} onOpenChange={setAddGroupOpen}>
                  <PopoverTrigger asChild>
                    <Button size="sm" variant="outline" disabled={availableGroups.length === 0}>
                      {tr("ربط مجموعة موجودة", "Link existing group")}
                    </Button>
                  </PopoverTrigger>
                  <PopoverContent className="w-[18rem] p-0" align="end">
                    <Command shouldFilter={true}>
                      <CommandInput placeholder={tr("ابحث…", "Search…")} />
                      <CommandList>
                        <CommandEmpty>{tr("لا نتائج.", "No results.")}</CommandEmpty>
                        <CommandGroup>
                          {availableGroups.map((group) => (
                            <CommandItem
                              key={group.id}
                              value={`${group.name} ${group.name_ar ?? ""}`}
                              onSelect={() => {
                                const next = groupFromLibrary(group.id);
                                if (next) setGroups((prev) => [...prev, next]);
                                setAddGroupOpen(false);
                              }}
                            >
                              <span className="text-start">{label(group)}</span>
                            </CommandItem>
                          ))}
                        </CommandGroup>
                      </CommandList>
                    </Command>
                  </PopoverContent>
                </Popover>
                <Button
                  size="sm"
                  onClick={() =>
                    setGroups((prev) => [
                      ...prev,
                      {
                        key: uid(),
                        name: "",
                        name_ar: "",
                        min_select: "0",
                        max_select: "1",
                        options: [newOption()],
                      },
                    ])
                  }
                >
                  <Plus className="me-1 size-4" />
                  {tr("مجموعة جديدة", "New group")}
                </Button>
              </div>
            </div>

            {groups.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {tr("لا توجد إضافات مرتبطة بهذا المنتج.", "No add-ons linked to this product.")}
              </p>
            ) : (
              <div className="space-y-4">
                {groups.map((group) => (
                  <div key={group.key} className="space-y-3 rounded-lg border border-border p-3">
                    <div className="grid items-end gap-2 sm:grid-cols-[2fr_2fr_1fr_1fr_auto]">
                      <div>
                        <Label className="text-xs">{tr("اسم المجموعة (عربي)", "Group (AR)")}</Label>
                        <Input
                          className="mt-1"
                          value={group.name_ar}
                          onChange={(event) =>
                            patchGroup(group.key, { name_ar: event.target.value })
                          }
                        />
                      </div>
                      <div>
                        <Label className="text-xs">
                          {tr("اسم المجموعة (إنجليزي)", "Group (EN)")}
                        </Label>
                        <Input
                          className="mt-1 text-start"
                          value={group.name}
                          onChange={(event) => patchGroup(group.key, { name: event.target.value })}
                        />
                      </div>
                      <div>
                        <Label className="text-xs">{tr("أقل اختيار", "Min")}</Label>
                        <Input
                          inputMode="numeric"
                          className="mt-1 text-end tabular-nums"
                          value={group.min_select}
                          onChange={(event) =>
                            patchGroup(group.key, { min_select: event.target.value })
                          }
                        />
                      </div>
                      <div>
                        <Label className="text-xs">{tr("أقصى اختيار", "Max")}</Label>
                        <Input
                          inputMode="numeric"
                          className="mt-1 text-end tabular-nums"
                          value={group.max_select}
                          onChange={(event) =>
                            patchGroup(group.key, { max_select: event.target.value })
                          }
                        />
                      </div>
                      <Button
                        size="icon"
                        variant="ghost"
                        className="text-destructive"
                        aria-label={tr("إزالة المجموعة", "Remove group")}
                        onClick={() =>
                          setGroups((prev) => prev.filter((row) => row.key !== group.key))
                        }
                      >
                        <Trash2 className="size-4" />
                      </Button>
                    </div>

                    <div className="space-y-2">
                      {group.options.map((option) => (
                        <div
                          key={option.key}
                          className="grid items-end gap-2 rounded-md bg-muted p-2 sm:grid-cols-[1.4fr_1.6fr_.8fr_1fr_1fr_auto]"
                        >
                          <div>
                            <Label className="text-xs">{tr("اسم الإضافة", "Add-on")}</Label>
                            <Input
                              className="mt-1"
                              value={option.name_ar || option.name}
                              onChange={(event) =>
                                patchOption(group.key, option.key, {
                                  name_ar: event.target.value,
                                  name: option.name || event.target.value,
                                })
                              }
                            />
                          </div>
                          <div>
                            <Label className="text-xs">
                              {tr("خامة المخزن المستهلكة", "Raw material")}
                            </Label>
                            <RawMaterialCombobox
                              items={items.data ?? []}
                              value={option.item_id}
                              onValueChange={(next) =>
                                patchOption(group.key, option.key, { item_id: next })
                              }
                              onSelected={() =>
                                quantityRefs.current[`modifier-${group.key}-${option.key}`]?.focus()
                              }
                              lang={lang}
                              currency={currency}
                              emptyLabel={tr("بدون خامة", "None")}
                            />
                          </div>
                          <div>
                            <Label className="text-xs">{tr("كمية الاستهلاك", "Deduction")}</Label>
                            <Input
                              ref={(node) => {
                                quantityRefs.current[`modifier-${group.key}-${option.key}`] = node;
                              }}
                              inputMode="decimal"
                              className="mt-1 text-end tabular-nums"
                              value={option.quantity}
                              onChange={(event) =>
                                patchOption(group.key, option.key, { quantity: event.target.value })
                              }
                            />
                          </div>
                          <div>
                            <Label className="text-xs">{tr("تكلفة الإضافة", "Add-on cost")}</Label>
                            <div className="mt-1 rounded-md border border-border bg-background px-3 py-2 text-sm tabular-nums">
                              {formatMoney(
                                lineCost(option.item_id, option.quantity),
                                currency,
                                lang,
                              )}
                            </div>
                          </div>
                          <div>
                            <Label className="text-xs">
                              {tr("سعر البيع الإضافي", "Extra price")}
                            </Label>
                            <Input
                              inputMode="decimal"
                              className="mt-1 text-end tabular-nums"
                              value={option.price_delta}
                              onChange={(event) =>
                                patchOption(group.key, option.key, {
                                  price_delta: event.target.value,
                                })
                              }
                            />
                          </div>
                          <Button
                            size="icon"
                            variant="ghost"
                            className="text-destructive"
                            aria-label={tr("حذف الخيار", "Remove option")}
                            onClick={() =>
                              patchGroup(group.key, {
                                options: group.options.filter((row) => row.key !== option.key),
                              })
                            }
                          >
                            <Trash2 className="size-4" />
                          </Button>
                        </div>
                      ))}
                    </div>

                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() =>
                        patchGroup(group.key, { options: [...group.options, newOption()] })
                      }
                    >
                      <Plus className="me-1 size-4" />
                      {tr("إضافة خيار جديد للمجموعة", "Add option")}
                    </Button>
                  </div>
                ))}
              </div>
            )}
          </section>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {tr("إلغاء", "Cancel")}
          </Button>
          <Button onClick={() => save.mutate()} disabled={save.isPending}>
            {tr("حفظ المنتج بالكامل ومكوناته", "Save product with recipe & add-ons")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
