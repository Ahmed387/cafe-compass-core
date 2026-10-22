import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Pencil, Plus } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
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
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
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
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/addons")({
  head: () => ({
    meta: [
      { title: "Add-ons — 20s Coffee" },
      { name: "description", content: "Manage the add-ons the cashier can pick for any drink." },
      { property: "og:title", content: "Add-ons — 20s Coffee" },
      { property: "og:description", content: "Add-on groups, options and prices for the POS." },
    ],
  }),
  component: AddonsPage,
});

type Option = {
  id: string;
  name: string;
  name_ar: string | null;
  price_delta: number;
  is_active: boolean;
  display_order: number | null;
};
type Group = {
  id: string;
  name: string;
  name_ar: string | null;
  is_active: boolean;
  max_select: number;
  display_order: number | null;
  modifier_options: Option[];
  product_modifier_groups: Array<{ product_id: string }>;
};

type GroupForm = { id: string | null; name_ar: string; name: string; max_select: string };
type OptionForm = { id: string | null; group_id: string; name_ar: string; name: string; price: string };

// Lists the POS reads its add-ons from; refreshed after every change here.
const RELATED_KEYS = ["addon-groups", "pos-all-modifier-groups", "pos-products", "studio-modifier-library"];

function AddonsPage() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { can, me } = useAuth();
  const queryClient = useQueryClient();
  const canView = can("products.view");
  // Same rule as the menu studio: the owner edits the catalog.
  const isSuperAdmin = me?.roleNames.includes("Super Admin") ?? false;
  const canEdit = isSuperAdmin && (can("products.update") || can("products.create"));

  const [groupForm, setGroupForm] = useState<GroupForm | null>(null);
  const [optionForm, setOptionForm] = useState<OptionForm | null>(null);

  const groups = useQuery({
    queryKey: ["addon-groups"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("modifier_groups")
        .select(
          "id, name, name_ar, is_active, max_select, display_order, modifier_options(id, name, name_ar, price_delta, is_active, display_order), product_modifier_groups(product_id)",
        )
        .order("display_order", { ascending: true, nullsFirst: false })
        .order("created_at", { ascending: true });
      if (error) throw error;
      return (data ?? []) as unknown as Group[];
    },
  });

  const refresh = () =>
    Promise.all(RELATED_KEYS.map((key) => queryClient.invalidateQueries({ queryKey: [key] })));

  const saveGroup = useMutation({
    mutationFn: async (form: GroupForm) => {
      const row = {
        name_ar: form.name_ar.trim(),
        name: form.name.trim() || form.name_ar.trim(),
        max_select: Math.max(1, Number(form.max_select) || 1),
      };
      if (form.id) {
        const { error } = await supabase.from("modifier_groups").update(row).eq("id", form.id);
        if (error) throw error;
      } else {
        const { error } = await supabase.from("modifier_groups").insert({
          ...row,
          company_id: me!.profile.company_id,
          min_select: 0,
          is_active: true,
          display_order: (groups.data?.length ?? 0) + 1,
        });
        if (error) throw error;
      }
    },
    onSuccess: async () => {
      setGroupForm(null);
      await refresh();
      toast.success(ar ? "اتحفظت المجموعة" : "Group saved");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const saveOption = useMutation({
    mutationFn: async (form: OptionForm) => {
      const row = {
        name_ar: form.name_ar.trim(),
        name: form.name.trim() || form.name_ar.trim(),
        price_delta: Math.max(0, Number(form.price) || 0),
      };
      if (form.id) {
        const { error } = await supabase.from("modifier_options").update(row).eq("id", form.id);
        if (error) throw error;
      } else {
        const group = groups.data?.find((g) => g.id === form.group_id);
        const { error } = await supabase.from("modifier_options").insert({
          ...row,
          group_id: form.group_id,
          is_active: true,
          display_order: (group?.modifier_options.length ?? 0) + 1,
        });
        if (error) throw error;
      }
    },
    onSuccess: async () => {
      setOptionForm(null);
      await refresh();
      toast.success(ar ? "اتحفظت الإضافة" : "Add-on saved");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  // Add-ons are hidden, never deleted, so old invoices keep their lines intact.
  const toggle = useMutation({
    mutationFn: async (input: { table: "modifier_groups" | "modifier_options"; id: string; active: boolean }) => {
      const { error } = await supabase.from(input.table).update({ is_active: input.active }).eq("id", input.id);
      if (error) throw error;
    },
    onSuccess: refresh,
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!canView) return <NoPermission message={ar ? "مش متاح ليك" : "No access"} />;

  const list = groups.data ?? [];
  const optionCount = list.reduce((sum, g) => sum + g.modifier_options.length, 0);

  return (
    <div className="animate-fade-in space-y-4">
      <PageHeader
        title={ar ? "الإضافات" : "Add-ons"}
        description={
          ar
            ? "كل إضافة شغالة هنا بتظهر للكاشير في زرار «+ إضافات» جنب أي صنف في الطلب."
            : "Every active add-on here shows to the cashier under “+ Add-ons” on any order line."
        }
        action={
          canEdit && (
            <Button icon={Plus} onClick={() => setGroupForm({ id: null, name_ar: "", name: "", max_select: "1" })}>
              {ar ? "مجموعة جديدة" : "New group"}
            </Button>
          )
        }
      />

      <p className="text-sm text-muted-foreground">
        {ar
          ? `${list.length} مجموعة · ${optionCount} إضافة. اللي بتقفله بيختفي من عند الكاشير بس، وبيفضل في الفواتير القديمة زي ما هو.`
          : `${list.length} groups · ${optionCount} add-ons. Turning one off only hides it from the cashier; old invoices keep it.`}
      </p>

      {groups.isLoading ? (
        <p className="text-sm text-muted-foreground">{ar ? "جاري التحميل..." : "Loading..."}</p>
      ) : list.length === 0 ? (
        <EmptyState message={ar ? "مفيش إضافات لسه. اعمل أول مجموعة." : "No add-ons yet. Create the first group."} />
      ) : (
        <div className="grid gap-4 xl:grid-cols-2">
          {list.map((group) => {
            const options = [...group.modifier_options].sort(
              (a, b) => (a.display_order ?? 0) - (b.display_order ?? 0),
            );
            return (
              <Card key={group.id} className={group.is_active ? "" : "opacity-60"}>
                <CardHeader className="flex flex-row flex-wrap items-center justify-between gap-3 space-y-0">
                  <div className="min-w-0">
                    <CardTitle className="text-lg">{group.name_ar || group.name}</CardTitle>
                    <p className="mt-1 text-xs text-muted-foreground">
                      {group.name_ar && group.name !== group.name_ar ? `${group.name} · ` : ""}
                      {group.max_select > 1
                        ? ar
                          ? `يختار لحد ${group.max_select}`
                          : `Up to ${group.max_select}`
                        : ar
                          ? "يختار واحدة بس"
                          : "Pick one"}
                      {" · "}
                      {ar
                        ? `مربوطة بـ ${group.product_modifier_groups.length} صنف`
                        : `Linked to ${group.product_modifier_groups.length} products`}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant="outline" className={group.is_active ? "border-emerald-300 text-emerald-700" : ""}>
                      {group.is_active ? (ar ? "بتظهر للكاشير" : "Shown") : ar ? "مخفية" : "Hidden"}
                    </Badge>
                    {canEdit && (
                      <>
                        <Switch
                          checked={group.is_active}
                          aria-label={ar ? "إظهار المجموعة للكاشير" : "Show group to cashier"}
                          onCheckedChange={(active) => toggle.mutate({ table: "modifier_groups", id: group.id, active })}
                        />
                        <Button
                          size="icon"
                          variant="ghost"
                          aria-label={ar ? "تعديل المجموعة" : "Edit group"}
                          onClick={() =>
                            setGroupForm({
                              id: group.id,
                              name_ar: group.name_ar ?? "",
                              name: group.name,
                              max_select: String(group.max_select || 1),
                            })
                          }
                        >
                          <Pencil className="size-4" />
                        </Button>
                      </>
                    )}
                  </div>
                </CardHeader>
                <CardContent className="space-y-3">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-start">{ar ? "الإضافة" : "Add-on"}</TableHead>
                        <TableHead className="w-28 text-center">{ar ? "السعر الزيادة" : "Extra price"}</TableHead>
                        <TableHead className="w-24 text-center">{ar ? "ظاهرة" : "Shown"}</TableHead>
                        {canEdit && <TableHead className="w-12" />}
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {options.length === 0 && (
                        <TableRow>
                          <TableCell colSpan={4} className="text-center text-sm text-muted-foreground">
                            {ar ? "مفيش إضافات في المجموعة دي." : "No add-ons in this group."}
                          </TableCell>
                        </TableRow>
                      )}
                      {options.map((option) => (
                        <TableRow key={option.id} className={option.is_active ? "" : "opacity-50"}>
                          <TableCell className="text-start">
                            <span className="font-medium">{option.name_ar || option.name}</span>
                            {option.name_ar && option.name !== option.name_ar && (
                              <span className="block text-xs text-muted-foreground" dir="auto">
                                {option.name}
                              </span>
                            )}
                          </TableCell>
                          <TableCell className="text-center tabular-nums">
                            +{formatMoney(Number(option.price_delta), me?.company?.currency ?? "EGP", lang)}
                          </TableCell>
                          <TableCell className="text-center">
                            <Switch
                              checked={option.is_active}
                              disabled={!canEdit}
                              aria-label={ar ? "إظهار الإضافة للكاشير" : "Show add-on to cashier"}
                              onCheckedChange={(active) =>
                                toggle.mutate({ table: "modifier_options", id: option.id, active })
                              }
                            />
                          </TableCell>
                          {canEdit && (
                            <TableCell className="text-center">
                              <Button
                                size="icon"
                                variant="ghost"
                                aria-label={ar ? "تعديل الإضافة" : "Edit add-on"}
                                onClick={() =>
                                  setOptionForm({
                                    id: option.id,
                                    group_id: group.id,
                                    name_ar: option.name_ar ?? "",
                                    name: option.name,
                                    price: String(option.price_delta),
                                  })
                                }
                              >
                                <Pencil className="size-4" />
                              </Button>
                            </TableCell>
                          )}
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                  {canEdit && (
                    <Button
                      variant="outline"
                      size="sm"
                      icon={Plus}
                      onClick={() =>
                        setOptionForm({ id: null, group_id: group.id, name_ar: "", name: "", price: "" })
                      }
                    >
                      {ar ? "إضافة اختيار" : "Add option"}
                    </Button>
                  )}
                </CardContent>
              </Card>
            );
          })}
        </div>
      )}

      <Dialog open={Boolean(groupForm)} onOpenChange={(open) => !open && setGroupForm(null)}>
        <DialogContent dir={ar ? "rtl" : "ltr"}>
          <DialogHeader>
            <DialogTitle>
              {groupForm?.id ? (ar ? "تعديل المجموعة" : "Edit group") : ar ? "مجموعة إضافات جديدة" : "New add-on group"}
            </DialogTitle>
          </DialogHeader>
          {groupForm && (
            <div className="grid gap-3">
              <div className="grid gap-1.5">
                <Label htmlFor="group-ar">{ar ? "الاسم بالعربي" : "Arabic name"}</Label>
                <Input
                  id="group-ar"
                  placeholder={ar ? "مثال: بدائل الحليب" : "e.g. بدائل الحليب"}
                  value={groupForm.name_ar}
                  onChange={(e) => setGroupForm({ ...groupForm, name_ar: e.target.value })}
                />
              </div>
              <div className="grid gap-1.5">
                <Label htmlFor="group-en">{ar ? "الاسم بالإنجليزي (اختياري)" : "English name (optional)"}</Label>
                <Input
                  id="group-en"
                  dir="ltr"
                  placeholder="Milk options"
                  value={groupForm.name}
                  onChange={(e) => setGroupForm({ ...groupForm, name: e.target.value })}
                />
              </div>
              <div className="grid gap-1.5">
                <Label htmlFor="group-max">{ar ? "الكاشير يختار لحد كام إضافة منها؟" : "How many can the cashier pick?"}</Label>
                <Input
                  id="group-max"
                  type="number"
                  min={1}
                  className="w-28"
                  value={groupForm.max_select}
                  onChange={(e) => setGroupForm({ ...groupForm, max_select: e.target.value })}
                />
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setGroupForm(null)}>
              {ar ? "إلغاء" : "Cancel"}
            </Button>
            <Button
              disabled={!groupForm?.name_ar.trim() || saveGroup.isPending}
              onClick={() => groupForm && saveGroup.mutate(groupForm)}
            >
              {ar ? "حفظ" : "Save"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(optionForm)} onOpenChange={(open) => !open && setOptionForm(null)}>
        <DialogContent dir={ar ? "rtl" : "ltr"}>
          <DialogHeader>
            <DialogTitle>
              {optionForm?.id ? (ar ? "تعديل الإضافة" : "Edit add-on") : ar ? "إضافة جديدة" : "New add-on"}
              {optionForm && (() => {
                const group = list.find((g) => g.id === optionForm.group_id);
                return group ? ` — ${group.name_ar || group.name}` : "";
              })()}
            </DialogTitle>
          </DialogHeader>
          {optionForm && (
            <div className="grid gap-3">
              <div className="grid gap-1.5">
                <Label htmlFor="option-ar">{ar ? "الاسم بالعربي" : "Arabic name"}</Label>
                <Input
                  id="option-ar"
                  placeholder={ar ? "مثال: لبن جوز هند" : "e.g. لبن جوز هند"}
                  value={optionForm.name_ar}
                  onChange={(e) => setOptionForm({ ...optionForm, name_ar: e.target.value })}
                />
              </div>
              <div className="grid gap-1.5">
                <Label htmlFor="option-en">{ar ? "الاسم بالإنجليزي (اختياري)" : "English name (optional)"}</Label>
                <Input
                  id="option-en"
                  dir="ltr"
                  placeholder="Coconut milk"
                  value={optionForm.name}
                  onChange={(e) => setOptionForm({ ...optionForm, name: e.target.value })}
                />
              </div>
              <div className="grid gap-1.5">
                <Label htmlFor="option-price">{ar ? "السعر اللي بيتزود على الصنف" : "Extra price"}</Label>
                <Input
                  id="option-price"
                  type="number"
                  min={0}
                  className="w-32"
                  value={optionForm.price}
                  onChange={(e) => setOptionForm({ ...optionForm, price: e.target.value })}
                />
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setOptionForm(null)}>
              {ar ? "إلغاء" : "Cancel"}
            </Button>
            <Button
              disabled={!optionForm?.name_ar.trim() || saveOption.isPending}
              onClick={() => optionForm && saveOption.mutate(optionForm)}
            >
              {ar ? "حفظ" : "Save"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
