import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { AlertTriangle, ShieldAlert } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { preResetBackup } from "@/lib/reset.functions";

const CONFIRM_TEXT = "RESET-20S";

/** The nine independently resettable operational modules. */
const RESET_TARGETS = [
  { key: "orders", ar: "مبيعات وطلبات الكاشير والفواتير", en: "Sales, orders & receipts" },
  { key: "shifts", ar: "سجلات الورديات ومطابقة النقدية", en: "Shifts & cash reconciliation" },
  { key: "purchases", ar: "فواتير المشتريات ودفعات الموردين", en: "Purchases & supplier payments" },
  { key: "purchase_returns", ar: "مرتجعات المشتريات", en: "Purchase returns" },
  { key: "expenses", ar: "المصروفات النقدية والتشغيلية", en: "Cash & operating expenses" },
  {
    key: "stock_movements",
    ar: "حركات المخزون وتصفير أرصدة الأصناف",
    en: "Stock movements & item balances",
  },
  { key: "cash_transactions", ar: "حركات الخزينة وسجلات الصندوق", en: "Treasury & cash records" },
  { key: "loyalty", ar: "كاش باك العملاء (المحافظ والحركات)", en: "Customer cashback (wallets & history)" },
  { key: "attendance", ar: "شيت الحضور والغياب للموظفين", en: "Staff attendance sheet" },
] as const;

/** Super-admin only: wipes selected operational modules after a safety backup. */
export function DangerZonePanel() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const queryClient = useQueryClient();
  const runBackup = useServerFn(preResetBackup);
  const [open, setOpen] = useState(false);
  const [confirm, setConfirm] = useState("");
  const [targets, setTargets] = useState<string[]>([]);

  const isSuperAdmin = useQuery({
    queryKey: ["is-super-admin"],
    enabled: Boolean(me),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("is_super_admin");
      if (error) throw error;
      return Boolean(data);
    },
  });

  const toggle = (key: string, checked: boolean) =>
    setTargets((prev) => (checked ? [...new Set([...prev, key])] : prev.filter((k) => k !== key)));

  const reset = useMutation({
    mutationFn: async () => {
      // 1. Safety net: never delete anything without a fresh Drive snapshot.
      const { backup } = await runBackup({ data: { confirm } });
      // 2. Atomic server-side wipe of the selected modules only.
      const { data, error } = await supabase.rpc("execute_operational_reset", {
        p_confirm: CONFIRM_TEXT,
        p_targets: targets,
      });
      if (error) throw new Error(error.message);
      return { backup, result: data };
    },
    onSuccess: (result) => {
      setOpen(false);
      setConfirm("");
      setTargets([]);
      queryClient.invalidateQueries();
      toast.success(
        ar
          ? `تم تصفير الوحدات المختارة بنجاح. نسخة الحماية: ${result.backup.file_name}`
          : `Selected modules reset successfully. Safety backup: ${result.backup.file_name}`,
      );
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : friendlyError(error, lang)),
  });

  if (isSuperAdmin.data !== true) return null;

  return (
    <Card className="mt-4 animate-fade-in border-destructive/50">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base text-destructive">
          <ShieldAlert className="h-4 w-4" />
          {ar ? "منطقة الخطر: تصفير بيانات التشغيل التجريبية" : "Danger zone: reset trial data"}
        </CardTitle>
        <p className="text-sm text-muted-foreground">
          {ar
            ? "اختار الوحدات اللي عايز تصفّرها. المنتجات والوصفات والتصنيفات والمستخدمين والأدوار والشركاء مش هيتأثروا، وهنعمل نسخة احتياطية كاملة على درايف قبل أي حذف."
            : "Pick the modules you want to wipe. Products, recipes, categories, users, roles and partners are kept, and a full Drive backup is taken before anything is deleted."}
        </p>
      </CardHeader>
      <CardContent>
        <Button
          variant="destructive"
          className="gap-2 transition-all duration-200"
          onClick={() => setOpen(true)}
        >
          <AlertTriangle className="h-4 w-4" />
          {ar ? "تصفير المعاملات" : "Reset transactions"}
        </Button>
      </CardContent>

      <Dialog
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) {
            setConfirm("");
            setTargets([]);
          }
        }}
      >
        <DialogContent className="max-h-[90vh] overflow-y-auto transition-all duration-200">
          <DialogHeader>
            <DialogTitle className="text-destructive">
              {ar ? "تأكيد التصفير النهائي" : "Confirm permanent reset"}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
              {ar
                ? "الخطوة دي مش بترجع. هنرفع نسخة 20s_backup_pre_reset على جوجل درايف أولاً، وبعدها هنحذف الوحدات المختارة نهائياً."
                : "This cannot be undone. A 20s_backup_pre_reset snapshot is uploaded to Google Drive first, then the selected modules are permanently deleted."}
            </p>

            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="transition-all duration-200"
                onClick={() => setTargets(RESET_TARGETS.map((item) => item.key))}
              >
                {ar ? "تحديد الكل" : "Select all"}
              </Button>
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="transition-all duration-200"
                onClick={() => setTargets([])}
              >
                {ar ? "إلغاء التحديد" : "Clear selection"}
              </Button>
            </div>

            <div className="space-y-2 rounded-md border border-border p-3">
              {RESET_TARGETS.map((item) => (
                <label
                  key={item.key}
                  htmlFor={`reset-${item.key}`}
                  className="flex cursor-pointer items-center gap-3 rounded-md px-2 py-1.5 text-sm transition-colors hover:bg-muted/60"
                >
                  <Checkbox
                    id={`reset-${item.key}`}
                    checked={targets.includes(item.key)}
                    onCheckedChange={(checked) => toggle(item.key, checked === true)}
                  />
                  <span>{ar ? item.ar : item.en}</span>
                </label>
              ))}
            </div>

            <div className="grid gap-2">
              <Label htmlFor="reset-confirm">
                {ar ? `اكتب ${CONFIRM_TEXT} للتأكيد` : `Type ${CONFIRM_TEXT} to confirm`}
              </Label>
              <Input
                id="reset-confirm"
                value={confirm}
                autoComplete="off"
                placeholder={CONFIRM_TEXT}
                onChange={(event) => setConfirm(event.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>
              {ar ? "إلغاء" : "Cancel"}
            </Button>
            <Button
              variant="destructive"
              className="transition-all duration-200"
              disabled={confirm !== CONFIRM_TEXT || targets.length === 0 || reset.isPending}
              onClick={() => reset.mutate()}
            >
              {reset.isPending
                ? ar
                  ? "جارٍ التصفير..."
                  : "Resetting..."
                : ar
                  ? "تصفير نهائي"
                  : "Reset permanently"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
