import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";

import { EmptyState } from "@/components/layout/AppShell";
import { InfoTip } from "@/components/shared/InfoTip";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import { businessMonth, businessToday } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Person = { id: string; display_name?: string | null; first_name?: string; last_name?: string | null };
type Advance = {
  id: string;
  user_id: string;
  amount: number;
  deducted_amount: number;
  advance_date: string;
  deduct_from: string | null;
  reason: string | null;
  status: string;
  user_profiles: Person | null;
};

const personName = (row: Person | null | undefined) =>
  row?.display_name || [row?.first_name, row?.last_name].filter(Boolean).join(" ") || "—";

/** YYYY-MM → "Oct 2026" / "أكتوبر 2026". */
function monthLabel(month: string | null | undefined, lang: "ar" | "en") {
  if (!month) return "—";
  return new Intl.DateTimeFormat(lang === "ar" ? "ar-EG" : "en-GB", { month: "long", year: "numeric", timeZone: "UTC" })
    .format(new Date(`${month.slice(0, 7)}-01T00:00:00Z`));
}

/** Staff advances (سلف): when they're deducted, how much is left, and Super Admin edits. */
export function StaffAdvancesTab({ staff, canPayroll }: { staff: Person[]; canPayroll: boolean }) {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const isSuperAdmin = Boolean(me?.isRoot || me?.roleNames.includes("Super Admin"));
  const qc = useQueryClient();
  const money = (v: number) => formatMoney(v, me?.company?.currency ?? "EGP", lang);

  const [createOpen, setCreateOpen] = useState(false);
  const [form, setForm] = useState({ user_id: "", amount: "", advance_date: businessToday(), deduct_month: businessMonth(), reason: "" });
  const [editing, setEditing] = useState<Advance | null>(null);
  const [edit, setEdit] = useState({ amount: "", deduct_month: "", reason: "" });

  const advances = useQuery({
    queryKey: ["employee-advances"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("employee_advances")
        .select("id, user_id, amount, deducted_amount, advance_date, deduct_from, reason, status, user_profiles!employee_advances_user_id_fkey(display_name, first_name, last_name)")
        .order("advance_date", { ascending: false })
        .limit(200);
      if (error) throw error;
      return (data ?? []) as unknown as Advance[];
    },
  });

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["employee-advances"] });
    qc.invalidateQueries({ queryKey: ["hr-preview"] });
  };

  const create = useMutation({
    mutationFn: async () => {
      const amount = Number(form.amount);
      if (!form.user_id || !(amount > 0)) throw new Error(t("fin.invalidAmount"));
      const { error } = await supabase.rpc("create_advance", {
        _user_id: form.user_id, _amount: amount, _advance_date: form.advance_date,
        _deduct_month: `${form.deduct_month}-01`,
        ...(form.reason.trim() ? { _reason: form.reason.trim() } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(t("common.saved"));
      setCreateOpen(false);
      setForm({ user_id: "", amount: "", advance_date: businessToday(), deduct_month: businessMonth(), reason: "" });
      refresh();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const save = useMutation({
    mutationFn: async () => {
      if (!editing) return;
      const { error } = await supabase.rpc("update_employee_advance", {
        _advance_id: editing.id, _amount: Number(edit.amount), _deduct_month: `${edit.deduct_month}-01`,
        ...(edit.reason.trim() ? { _reason: edit.reason.trim() } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(t("common.saved")); setEditing(null); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const cancel = useMutation({
    mutationFn: async (id: string) => {
      const reason = window.prompt(t("att.cancelReason"));
      if (!reason) throw new Error("cancelled");
      const { error } = await supabase.rpc("cancel_advance", { _advance_id: id, _reason: reason });
      if (error) throw error;
    },
    onSuccess: refresh,
    onError: (e) => { if ((e as Error).message !== "cancelled") toast.error(friendlyError(e, lang)); },
  });

  const rows = advances.data ?? [];
  const editAmount = Number(edit.amount);
  const editValid = editing !== null && editAmount > 0 && editAmount >= Number(editing.deducted_amount) && Boolean(edit.deduct_month);

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="flex items-center gap-1.5 text-sm text-muted-foreground">
          {ar ? "السلفة بتتخصم من مرتب الشهر اللي تختاره، ولو المرتب مكفاش الباقي بيترحّل للشهر اللي بعده." : "An advance is deducted from the payroll month you choose; anything the salary can't cover rolls to the next month."}
          <InfoTip>{ar ? "السوبر أدمن يقدر يعدّل المبلغ أو شهر الخصم في أي وقت قبل ما السلفة تتخصم بالكامل." : "The Super Admin can change the amount or the month any time before it's fully deducted."}</InfoTip>
        </p>
        {canPayroll && <Button onClick={() => setCreateOpen(true)}>{t("att.addAdvance")}</Button>}
      </div>

      {rows.length === 0 ? (
        <EmptyState message={t("att.emptyAdvances")} />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("att.date")}</TableHead>
                <TableHead>{t("att.employee")}</TableHead>
                <TableHead>{t("att.amount")}</TableHead>
                <TableHead>{ar ? "تتخصم من" : "Deducted from"}</TableHead>
                <TableHead>{ar ? "اتخصم / باقي" : "Recovered / left"}</TableHead>
                <TableHead>{t("att.reason")}</TableHead>
                <TableHead>{t("att.status")}</TableHead>
                {canPayroll && <TableHead />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => {
                const left = Number(row.amount) - Number(row.deducted_amount);
                const done = row.status === "active" && left <= 0;
                const open = row.status === "active" && left > 0;
                return (
                  <TableRow key={row.id}>
                    <TableCell>{formatDate(row.advance_date, lang)}</TableCell>
                    <TableCell>{personName(row.user_profiles)}</TableCell>
                    <TableCell className="tabular-nums">{money(Number(row.amount))}</TableCell>
                    <TableCell>{monthLabel(row.deduct_from ?? row.advance_date, lang)}</TableCell>
                    <TableCell className="tabular-nums text-xs">{money(Number(row.deducted_amount))} / {money(Math.max(left, 0))}</TableCell>
                    <TableCell className="text-muted-foreground">{row.reason ?? "—"}</TableCell>
                    <TableCell>
                      <Badge variant={row.status === "cancelled" ? "outline" : done ? "secondary" : "default"}>
                        {row.status === "cancelled" ? t("att.cancelled") : done ? t("att.settled") : t("att.outstanding")}
                      </Badge>
                    </TableCell>
                    {canPayroll && (
                      <TableCell className="space-x-1 whitespace-nowrap">
                        {open && isSuperAdmin && (
                          <Button size="sm" variant="outline" onClick={() => {
                            setEditing(row);
                            setEdit({ amount: String(row.amount), deduct_month: (row.deduct_from ?? row.advance_date).slice(0, 7), reason: row.reason ?? "" });
                          }}>{ar ? "تعديل" : "Edit"}</Button>
                        )}
                        {open && Number(row.deducted_amount) === 0 && (
                          <Button size="sm" variant="ghost" disabled={cancel.isPending} onClick={() => cancel.mutate(row.id)}>{t("common.cancel")}</Button>
                        )}
                      </TableCell>
                    )}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent dir={ar ? "rtl" : "ltr"}>
          <DialogHeader><DialogTitle>{t("att.addAdvance")}</DialogTitle></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label>{t("att.employee")}</Label>
              <Select value={form.user_id} onValueChange={(value) => setForm({ ...form, user_id: value })}>
                <SelectTrigger><SelectValue placeholder={t("att.employee")} /></SelectTrigger>
                <SelectContent>{staff.map((p) => <SelectItem key={p.id} value={p.id}>{personName(p)}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label htmlFor="adv-amount">{t("att.amount")}</Label>
                <Input id="adv-amount" type="number" min="0" step="0.01" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="adv-date">{t("att.date")}</Label>
                <Input id="adv-date" type="date" value={form.advance_date} onChange={(e) => {
                  const day = e.target.value;
                  setForm({ ...form, advance_date: day, deduct_month: form.deduct_month < day.slice(0, 7) ? day.slice(0, 7) : form.deduct_month });
                }} />
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="adv-month">{ar ? "تتخصم من مرتب شهر" : "Deduct from payroll month"}</Label>
              <Input id="adv-month" type="month" min={form.advance_date.slice(0, 7)} value={form.deduct_month} onChange={(e) => setForm({ ...form, deduct_month: e.target.value })} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="adv-reason">{t("att.reason")}</Label>
              <Textarea id="adv-reason" value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} />
            </div>
          </div>
          <DialogFooter>
            <Button onClick={() => create.mutate()} disabled={!form.user_id || !form.amount || !form.deduct_month || create.isPending}>{t("common.save")}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(editing)} onOpenChange={(v) => !v && setEditing(null)}>
        <DialogContent dir={ar ? "rtl" : "ltr"}>
          <DialogHeader><DialogTitle>{ar ? "تعديل السلفة" : "Edit advance"}</DialogTitle></DialogHeader>
          {editing && (
            <div className="space-y-3">
              <p className="rounded-xl bg-muted/60 p-3 text-sm">
                {personName(editing.user_profiles)} · {ar ? "اتخصم منها" : "Recovered"} {money(Number(editing.deducted_amount))}
              </p>
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-2">
                  <Label htmlFor="edit-amount">{t("att.amount")}</Label>
                  <Input id="edit-amount" type="number" min={Number(editing.deducted_amount)} step="0.01" value={edit.amount} onChange={(e) => setEdit({ ...edit, amount: e.target.value })} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="edit-month">{ar ? "تتخصم من شهر" : "Deduct from"}</Label>
                  <Input id="edit-month" type="month" min={editing.advance_date.slice(0, 7)} value={edit.deduct_month} onChange={(e) => setEdit({ ...edit, deduct_month: e.target.value })} />
                </div>
              </div>
              {editAmount > 0 && editAmount < Number(editing.deducted_amount) && (
                <p className="text-xs text-destructive">{ar ? "المبلغ مينفعش يقل عن اللي اتخصم فعلاً." : "Amount can't be less than what was already recovered."}</p>
              )}
              <div className="space-y-2">
                <Label htmlFor="edit-reason">{t("att.reason")}</Label>
                <Textarea id="edit-reason" value={edit.reason} onChange={(e) => setEdit({ ...edit, reason: e.target.value })} />
              </div>
            </div>
          )}
          <DialogFooter><Button disabled={!editValid || save.isPending} onClick={() => save.mutate()}>{t("common.save")}</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
