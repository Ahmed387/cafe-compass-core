import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
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
import { supabase } from "@/integrations/supabase/client";
import { setUserPassword } from "@/lib/admin.functions";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence } from "@/lib/receipt";

import { PartnerDividendsPanel } from "./PartnerDividendsPanel";
import { PartnerManagingPanel } from "./PartnerManagingPanel";
import { PartnerAdvancesPanel } from "./PartnerAdvancesPanel";

export type PartnerRow = {
  id: string;
  name: string;
  email: string | null;
  phone: string | null;
  user_id: string | null;
  customer_id: string | null;
};

/** Full drill-down for one partner: money statement, personal tab and access. */
export function PartnerStatementDialog({
  partner,
  onClose,
}: {
  partner: PartnerRow | null;
  onClose: () => void;
}) {
  const { t, lang } = useI18n();
  const { me, can } = useAuth();
  const ar = lang === "ar";
  const currency = me?.company?.currency ?? "EGP";
  const queryClient = useQueryClient();
  const [password, setPassword] = useState("");

  const details = useQuery({
    queryKey: ["partner-statement", partner?.id],
    enabled: Boolean(partner),
    queryFn: async () => {
      if (!partner) return null;
      const [ledger, tabs, roles, userRoles] = await Promise.all([
        supabase
          .from("partner_ledger_transactions")
          .select("id, transaction_type, amount, transaction_date, description, status")
          .eq("partner_id", partner.id)
          .order("transaction_date", { ascending: false })
          .limit(100),
        supabase
          .from("partner_tab_orders")
          .select("id, order_id, total_amount, is_settled, created_at, orders(order_number)")
          .eq("partner_id", partner.id)
          .order("created_at", { ascending: false }),
        supabase.from("roles").select("id, name").order("name"),
        partner.user_id
          ? supabase.from("user_roles").select("role_id").eq("user_id", partner.user_id)
          : Promise.resolve({ data: [] as Array<{ role_id: string }> }),
      ]);
      return {
        ledger: ledger.data ?? [],
        tabs: tabs.data ?? [],
        roles: roles.data ?? [],
        roleIds: (userRoles.data ?? []).map((row) => row.role_id),
      };
    },
  });

  const balance = (details.data?.ledger ?? [])
    .filter((row) => row.status === "active")
    .reduce((sum, row) => sum + Number(row.amount), 0);
  const pendingTab = (details.data?.tabs ?? [])
    .filter((row) => !row.is_settled)
    .reduce((sum, row) => sum + Number(row.total_amount), 0);

  const toggleRole = useMutation({
    mutationFn: async (roleId: string) => {
      if (!partner?.user_id) throw new Error("no login account");
      const current = details.data?.roleIds ?? [];
      const next = current.includes(roleId)
        ? current.filter((id) => id !== roleId)
        : [...current, roleId];
      const { error } = await supabase.rpc("set_user_roles", {
        _user_id: partner.user_id,
        _role_ids: next,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["partner-statement"] });
      toast.success(ar ? "تم تحديث الأدوار." : "Roles updated.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const resetPassword = useMutation({
    mutationFn: async () => {
      if (!partner?.user_id) throw new Error("no login account");
      await setUserPassword({ data: { user_id: partner.user_id, password } });
    },
    onSuccess: () => {
      setPassword("");
      toast.success(ar ? "تم تغيير كلمة المرور." : "Password changed.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Dialog open={Boolean(partner)} onOpenChange={(value) => !value && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader className="text-start">
          <DialogTitle className="flex flex-wrap items-center gap-2">
            {partner?.name}
            <Badge className="border-amber-400/60 bg-amber-500/15 text-amber-700 dark:text-amber-300">
              {t("partners.title")}
            </Badge>
          </DialogTitle>
          <p className="text-xs text-muted-foreground">
            {[partner?.email, partner?.phone].filter(Boolean).join(" · ") || "—"}
          </p>
        </DialogHeader>

        <div className="grid gap-3 sm:grid-cols-2">
          <div className="rounded-lg border border-border bg-card p-3">
            <p className="text-xs text-muted-foreground">{t("partners.balance")}</p>
            <p className="text-xl font-bold tabular-nums">
              {formatMoney(balance, currency, lang)}
            </p>
          </div>
          <div className="rounded-lg border border-amber-400/50 bg-amber-500/5 p-3">
            <p className="text-xs text-muted-foreground">{t("ptab.unsettled")}</p>
            <p className="text-xl font-bold tabular-nums text-amber-700 dark:text-amber-300">
              {formatMoney(pendingTab, currency, lang)}
            </p>
          </div>
        </div>

        <div className="overflow-x-auto rounded-lg border border-border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-32 text-center">{t("common.date")}</TableHead>
                <TableHead className="min-w-40 text-start">{t("common.details")}</TableHead>
                <TableHead className="w-36 text-end">{t("common.amount")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(details.data?.ledger ?? []).map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="w-32 whitespace-nowrap text-center">
                    {formatDate(row.transaction_date, lang)}
                  </TableCell>
                  <TableCell className="min-w-40 text-start">
                    {row.description ?? row.transaction_type}
                  </TableCell>
                  <TableCell
                    className={`w-36 whitespace-nowrap text-end tabular-nums ${
                      Number(row.amount) < 0 ? "text-destructive" : ""
                    }`}
                  >
                    {formatMoney(row.amount, currency, lang)}
                  </TableCell>
                </TableRow>
              ))}
              {(details.data?.ledger ?? []).length === 0 && (
                <TableRow>
                  <TableCell colSpan={3} className="py-6 text-center text-muted-foreground">
                    {t("ptab.empty")}
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>

        {(details.data?.tabs ?? []).length > 0 && (
          <div className="overflow-x-auto rounded-lg border border-border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-28 text-center">#</TableHead>
                  <TableHead className="w-32 text-center">{t("common.date")}</TableHead>
                  <TableHead className="w-36 text-end">{t("common.amount")}</TableHead>
                  <TableHead className="w-28 text-center">{t("common.status")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(details.data?.tabs ?? []).map((row) => {
                  const rel = row.orders as unknown as
                    | { order_number: string }
                    | Array<{ order_number: string }>
                    | null;
                  const order = Array.isArray(rel) ? rel[0] : rel;
                  return (
                    <TableRow key={row.id}>
                      <TableCell className="w-28 text-center font-mono font-bold text-primary">
                        {invoiceSequence(order?.order_number ?? "")}
                      </TableCell>
                      <TableCell className="w-32 whitespace-nowrap text-center">
                        {formatDate(row.created_at, lang)}
                      </TableCell>
                      <TableCell className="w-36 whitespace-nowrap text-end tabular-nums">
                        {formatMoney(row.total_amount, currency, lang)}
                      </TableCell>
                      <TableCell className="w-28 text-center">
                        <Badge variant={row.is_settled ? "secondary" : "outline"}>
                          {row.is_settled ? t("ptab.settledFlag") : t("ptab.unsettled")}
                        </Badge>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        )}

        {partner && <PartnerManagingPanel partnerId={partner.id} userId={partner.user_id} partnerName={partner.name} />}
        {partner && <PartnerDividendsPanel partnerId={partner.id} />}
        {partner && <PartnerAdvancesPanel partnerId={partner.id} />}

        {can("users.edit") && partner?.user_id && (
          <div className="grid gap-3 rounded-lg border border-border bg-card p-3">
            <p className="text-sm font-semibold">{t("partners.access")}</p>
            <div className="flex flex-wrap gap-3">
              {(details.data?.roles ?? []).map((role) => (
                <Label key={role.id} className="flex items-center gap-2 text-sm">
                  <Checkbox
                    checked={(details.data?.roleIds ?? []).includes(role.id)}
                    disabled={toggleRole.isPending}
                    onCheckedChange={() => toggleRole.mutate(role.id)}
                  />
                  {role.name}
                </Label>
              ))}
            </div>
            <div className="flex flex-wrap items-end gap-2">
              <div className="grid gap-1">
                <Label htmlFor="partner-password">{t("partners.newPassword")}</Label>
                <Input
                  id="partner-password"
                  type="password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                />
              </div>
              <Button
                variant="outline"
                disabled={password.length < 8 || resetPassword.isPending}
                onClick={() => resetPassword.mutate()}
              >
                {t("partners.setPassword")}
              </Button>
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
