import { InfoTip } from "@/components/shared/InfoTip";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ChevronLeft, ChevronRight, Search, UsersRound } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { cn } from "@/lib/utils";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { StaffAdvancesTab } from "@/modules/governance/StaffAdvancesTab";
import { businessToday } from "@/core/finance/business-dates";

type DayStatus = "present" | "absent" | "leave" | "half_day" | "permission";
type StaffRow = { id: string; display_name: string | null; first_name: string; last_name: string | null; employee_code: string | null };
type AttendanceRow = { id: string; user_id: string; work_date: string; status: string; notes: string | null; permission_hours: number | null };

const statusStyles: Record<DayStatus, string> = {
  present: "border-success/40 bg-success/15 text-success",
  absent: "border-destructive/40 bg-destructive/15 text-destructive",
  leave: "border-accent/40 bg-accent/15 text-accent-foreground",
  half_day: "border-warning/50 bg-warning/15 text-warning-foreground",
  permission: "border-primary/40 bg-primary/15 text-primary",
};

const statuses: DayStatus[] = ["present", "absent", "leave", "half_day", "permission"];

function isoDate(date: Date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
function monthBounds(month: Date) {
  const start = new Date(month.getFullYear(), month.getMonth(), 1);
  const end = new Date(month.getFullYear(), month.getMonth() + 1, 0);
  return { start: isoDate(start), end: isoDate(end), days: end.getDate(), offset: (start.getDay() + 6) % 7 };
}

export function AttendancePage() {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const { can, me, currentBranchId } = useAuth();
  const queryClient = useQueryClient();
  const canManage = can("attendance.manage");
  const canPayroll = can("payroll.manage");
  const canViewAdvances = can("payroll.view") || canPayroll;
  const [month, setMonth] = useState(() => new Date());
  const [day, setDay] = useState(() => businessToday());
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [search, setSearch] = useState("");
  const [attendanceForm, setAttendanceForm] = useState<{ status: DayStatus; permissionHours: string; notes: string } | null>(null);
  const bounds = monthBounds(month);

  const staff = useQuery({
    queryKey: ["attendance-staff"],
    queryFn: async () => {
      const { data, error } = await supabase.from("user_profiles").select("id, display_name, first_name, last_name, employee_code").eq("is_active", true).order("first_name");
      if (error) throw error;
      return (data ?? []) as StaffRow[];
    },
  });
  const monthRecords = useQuery({
    queryKey: ["attendance-month", bounds.start, bounds.end],
    queryFn: async () => {
      const { data, error } = await supabase.from("attendance").select("id, user_id, work_date, status, notes, permission_hours").gte("work_date", bounds.start).lte("work_date", bounds.end);
      if (error) throw error;
      return (data ?? []) as AttendanceRow[];
    },
  });
  const name = (row: { display_name?: string | null; first_name?: string; last_name?: string | null } | null) => row?.display_name || [row?.first_name, row?.last_name].filter(Boolean).join(" ") || "—";
  const visibleStaff = useMemo(() => (staff.data ?? []).filter((person) => `${name(person)} ${person.employee_code ?? ""}`.toLowerCase().includes(search.trim().toLowerCase())), [staff.data, search]);
  const recordMap = useMemo(() => new Map((monthRecords.data ?? []).map((record) => [`${record.user_id}:${record.work_date}`, record])), [monthRecords.data]);
  const selected = selectedIds.length ? selectedIds : visibleStaff[0] ? [visibleStaff[0].id] : [];

  const setStatus = useMutation({
    mutationFn: async ({ status, permissionHours, notes }: { status: DayStatus; permissionHours?: string; notes?: string }) => {
      if (!selected.length) throw new Error("no-selection");
      const hours = status === "permission" ? Number(permissionHours) : null;
      if (status === "permission" && (!Number.isFinite(hours) || Number(hours) <= 0 || Number(hours) > 8)) throw new Error("invalid-hours");
      const results = await Promise.all(selected.map((userId) => supabase.rpc("upsert_attendance", { _user_id: userId, _work_date: day, _status: status, ...(hours !== null ? { _permission_hours: hours } : {}), ...(notes?.trim() ? { _notes: notes.trim() } : {}), ...(currentBranchId ? { _branch_id: currentBranchId } : {}) })));
      const failed = results.find((result) => result.error);
      if (failed?.error) throw failed.error;
    },
    onSuccess: () => {
      toast.success(ar ? `تم تحديث ${selected.length} موظف` : `${selected.length} staff updated`);
      setAttendanceForm(null);
      queryClient.invalidateQueries({ queryKey: ["attendance-month"] });
    },
    onError: (error) => toast.error((error as Error).message === "no-selection" ? (ar ? "اختر موظفًا واحدًا على الأقل" : "Select at least one employee") : (error as Error).message === "invalid-hours" ? (ar ? "ساعات الإذن لازم تكون أكبر من صفر وبحد أقصى 8 ساعات" : "Permission must be more than 0 and no more than 8 hours") : friendlyError(error, lang)),
  });

  const moveMonth = (step: number) => { const next = new Date(month.getFullYear(), month.getMonth() + step, 1); setMonth(next); setDay(isoDate(next)); };
  const allVisibleSelected = visibleStaff.length > 0 && visibleStaff.every((person) => selectedIds.includes(person.id));
  const toggleAll = () => setSelectedIds(allVisibleSelected ? [] : visibleStaff.map((person) => person.id));
  const monthLabel = new Intl.DateTimeFormat(ar ? "ar-EG" : "en-US", { month: "long", year: "numeric" }).format(month);
  const weekdays = ar ? ["الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت", "الأحد"] : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const statusLabel = (status: DayStatus) => status === "present" ? t("att.present") : status === "absent" ? t("att.absent") : status === "leave" ? t("att.leave") : status === "half_day" ? t("att.halfDay") : t("att.permission");

  if (!me) return <NoPermission message={t("common.noAccess")} />;
  return (
    <Tabs defaultValue="roster" className="space-y-4">
      <TabsList><TabsTrigger value="roster">{t("att.roster")}</TabsTrigger>{canViewAdvances && <TabsTrigger value="advances">{t("att.advances")}</TabsTrigger>}</TabsList>
      <TabsContent value="roster" className="mt-0">
        <section className="overflow-hidden rounded-2xl border border-sidebar-border bg-sidebar text-sidebar-foreground shadow-lg">
          <header className="flex flex-wrap items-center justify-between gap-4 border-b border-sidebar-border px-4 py-4 sm:px-6">
            <div><h2 className="font-display text-xl font-bold">{ar ? "لوحة الحضور الشهرية" : "Monthly attendance command"}</h2><p className="mt-1 text-sm text-sidebar-foreground/60">{ar ? `${staff.data?.length ?? 0} موظف نشط · تحديث مباشر` : `${staff.data?.length ?? 0} active staff · live updates`}</p></div>
            <div className="flex items-center gap-2"><Button variant="outline" size="icon" onClick={() => moveMonth(-1)} aria-label={ar ? "الشهر السابق" : "Previous month"}><ChevronRight className="size-4 rtl:rotate-180" /></Button><span className="min-w-36 text-center font-semibold">{monthLabel}</span><Button variant="outline" size="icon" onClick={() => moveMonth(1)} aria-label={ar ? "الشهر التالي" : "Next month"}><ChevronLeft className="size-4 rtl:rotate-180" /></Button></div>
          </header>
          <div className="grid lg:grid-cols-[20rem_minmax(0,1fr)]">
            <aside className="border-b border-sidebar-border p-4 lg:border-e lg:border-b-0">
              <div className="relative mb-3"><Search className="absolute start-3 top-1/2 size-4 -translate-y-1/2 text-sidebar-foreground/45" /><Input value={search} onChange={(event) => setSearch(event.target.value)} placeholder={ar ? "ابحث عن موظف…" : "Search staff…"} className="border-sidebar-border bg-sidebar-accent/40 ps-9 text-sidebar-foreground" /></div>
              <label className="mb-2 flex w-full cursor-pointer items-center gap-2 rounded-md px-3 py-2 text-sm font-medium text-sidebar-foreground hover:bg-sidebar-accent"><Checkbox checked={allVisibleSelected} onCheckedChange={toggleAll} /><span>{ar ? "تحديد كل الظاهر" : "Select visible"}</span><Badge variant="secondary" className="ms-auto">{selectedIds.length}</Badge></label>
              <div className="max-h-[32rem] space-y-1 overflow-y-auto pe-1">
                {visibleStaff.map((person) => { const checked = selectedIds.includes(person.id); return <label key={person.id} className={cn("flex w-full cursor-pointer items-center gap-3 rounded-md px-2 py-2.5 text-start text-sidebar-foreground hover:bg-sidebar-accent", checked && "bg-sidebar-accent")}><Checkbox checked={checked} onCheckedChange={() => setSelectedIds((ids) => checked ? ids.filter((id) => id !== person.id) : [...ids, person.id])} /><span className="grid size-9 shrink-0 place-items-center rounded-full border border-primary/30 bg-primary/15 text-xs font-bold text-primary">{name(person).slice(0, 2).toUpperCase()}</span><span className="min-w-0"><span className="block truncate text-sm font-semibold">{name(person)}</span><span className="block text-xs text-sidebar-foreground/50">{person.employee_code || "—"}</span></span></label>; })}
              </div>
            </aside>
            <main className="min-w-0 bg-background p-3 text-foreground sm:p-5">
              <div className="mb-4 flex flex-wrap items-center justify-between gap-3"><div><p className="text-sm font-bold">{ar ? "اختر يومًا ثم طبّق الحالة" : "Choose a day, then apply a status"}</p><p className="text-xs text-muted-foreground">{selected.length} {ar ? "موظف محدد" : "staff selected"} · {formatDate(day, lang)}</p></div><div className="flex flex-wrap gap-2">{statuses.map((status) => <Button key={status} size="sm" variant="outline" disabled={!canManage || setStatus.isPending || selected.length === 0} className={statusStyles[status]} onClick={() => status === "permission" ? setAttendanceForm({ status, permissionHours: "", notes: "" }) : setStatus.mutate({ status })}>{statusLabel(status)}</Button>)}<InfoTip title="حالات الحضور"><b>حاضر:</b> اشتغل يومه كامل، مفيش خصم.<br/><b>غائب:</b> ماجاش، بيتخصم يوم كامل.<br/><b>إجازة:</b> إجازة متفق عليها، مفيش خصم.<br/><b>نصف يوم:</b> اشتغل نص الوردية، بيتخصم نص يوم.<br/><b>إذن:</b> اتأخر أو مشي بدري كام ساعة، الخصم = الساعات ÷ 8 (ساعتين = ربع يوم).</InfoTip></div></div>
              <div className="grid grid-cols-7 gap-1.5">{weekdays.map((label) => <div key={label} className="py-2 text-center text-[11px] font-bold text-muted-foreground">{label}</div>)}{Array.from({ length: bounds.offset }).map((_, index) => <span key={`blank-${index}`} />)}{Array.from({ length: bounds.days }).map((_, index) => { const date = `${bounds.start.slice(0, 8)}${String(index + 1).padStart(2, "0")}`; const records = selected.map((id) => recordMap.get(`${id}:${date}`)).filter(Boolean) as AttendanceRow[]; const dayStatuses = records.map((record) => record.status as DayStatus); return <Button key={date} variant="ghost" className={cn("h-20 min-w-0 flex-col items-stretch justify-start gap-2 rounded-lg border border-border bg-card p-2 text-start", day === date && "border-primary ring-2 ring-primary/25")} onClick={() => setDay(date)}><span className="text-xs font-bold tabular-nums">{index + 1}</span><span className="mt-auto flex gap-1">{statuses.map((status) => dayStatuses.includes(status) && <span key={status} className={cn("h-1.5 flex-1 rounded-full", status === "present" ? "bg-success" : status === "absent" ? "bg-destructive" : status === "leave" ? "bg-accent" : status === "half_day" ? "bg-warning" : "bg-primary")} />)}</span>{selected.length === 1 && dayStatuses[0] && <span className={cn("truncate text-[10px] font-semibold", statusStyles[dayStatuses[0]])}>{statusLabel(dayStatuses[0])}{records[0]?.permission_hours ? ` · ${records[0].permission_hours}${ar ? "س" : "h"}` : ""}</span>}</Button>; })}</div>
              {monthRecords.isLoading && <p className="py-6 text-center text-sm text-muted-foreground">{ar ? "جاري تحميل الشهر…" : "Loading month…"}</p>}
              <div className="mt-4 flex flex-wrap gap-4 text-xs text-muted-foreground">{statuses.map((status) => <span key={status} className="flex items-center gap-1.5"><i className={cn("size-2 rounded-full", status === "present" ? "bg-success" : status === "absent" ? "bg-destructive" : status === "leave" ? "bg-accent" : status === "half_day" ? "bg-warning" : "bg-primary")} />{statusLabel(status)}</span>)}</div>
            </main>
          </div>
        </section>
      </TabsContent>
      {canViewAdvances && <TabsContent value="advances" className="mt-0"><StaffAdvancesTab staff={staff.data ?? []} canPayroll={canPayroll} /></TabsContent>}
      <Dialog open={Boolean(attendanceForm)} onOpenChange={(open) => !open && setAttendanceForm(null)}>
        <DialogContent>
          <DialogHeader><DialogTitle>{ar ? "تسجيل إذن بالساعات" : "Record hourly permission"}</DialogTitle></DialogHeader>
          <div className="space-y-4">
            <div className="rounded-lg border border-primary/25 bg-primary/10 p-3 text-sm text-foreground">{ar ? "الخصم بيتحسب كنسبة من يوم عمل 8 ساعات. مثال: إذن ساعتين = خصم ربع يوم." : "Deduction is proportional to an 8-hour workday. Example: 2 hours equals a quarter-day deduction."}</div>
            <div className="space-y-2"><Label>{ar ? "عدد ساعات الإذن" : "Permission hours"}</Label><Input type="number" min="0.25" max="8" step="0.25" value={attendanceForm?.permissionHours ?? ""} onChange={(event) => setAttendanceForm((form) => form ? { ...form, permissionHours: event.target.value } : form)} /></div>
            <div className="space-y-2"><Label>{ar ? "ملاحظات (اختياري)" : "Notes (optional)"}</Label><Textarea value={attendanceForm?.notes ?? ""} onChange={(event) => setAttendanceForm((form) => form ? { ...form, notes: event.target.value } : form)} placeholder={ar ? "مثال: تأخير ساعتين بموافقة المدير" : "Example: two-hour late arrival approved by manager"} /></div>
          </div>
          <DialogFooter><Button onClick={() => attendanceForm && setStatus.mutate(attendanceForm)} disabled={setStatus.isPending || !attendanceForm?.permissionHours}>{ar ? "حفظ الإذن" : "Save permission"}</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </Tabs>
  );
}
