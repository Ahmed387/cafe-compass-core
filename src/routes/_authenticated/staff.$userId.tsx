import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { ArrowLeft, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { ImageThumb } from "@/components/shared";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { deleteCompanyUser, deleteUserDocument, getUserDocuments, uploadUserDocument } from "@/lib/admin.functions";
import { ROOT_ADMIN_EMAIL, useAuth } from "@/lib/auth";
import { EmployeeEditDialog } from "@/modules/governance/EmployeeEditDialog";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { fileToPayload } from "@/lib/files";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/staff/$userId")({
  head: () => ({
    meta: [
      { title: "Employee file — 20s Coffee" },
      { name: "description", content: "Employee details, roles, attachments and payroll history." },
      { property: "og:title", content: "Employee file — 20s Coffee" },
      { property: "og:description", content: "Full employee record with roles and attachments." },
    ],
  }),
  component: StaffDetailPage,
});

const ATTENDANCE_STATUS_KEYS: Record<string, string> = {
  present: "att.present",
  absent: "att.absent",
  leave: "att.leave",
  half_day: "att.halfDay",
  permission: "att.permission",
};

function StaffDetailPage() {
  const { userId } = Route.useParams();
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const isSuperAdmin = me?.roleNames.includes("Super Admin") ?? false;
  const removeEmployee = useMutation({
    mutationFn: () => deleteCompanyUser({ data: { user_id: userId } }),
    onSuccess: (res) => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
      queryClient.invalidateQueries({ queryKey: ["hr-preview"] });
      toast.success(
        res?.mode === "archived"
          ? lang === "ar"
            ? "الموظف له سجلات، فاتأرشف واتقفل حسابه وسجلاته محفوظة"
            : "Employee has history, so they were archived and disabled; records kept"
          : lang === "ar"
            ? "تم حذف الموظف"
            : "Employee deleted",
      );
      navigate({ to: "/hr", search: { tab: "team" } });
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const [roleIds, setRoleIds] = useState<string[]>([]);

  const { data: profile } = useQuery({
    queryKey: ["staff", userId],
    enabled: can("users.view"),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("user_profiles")
        .select(
          "id, first_name, last_name, display_name, email, phone, employee_code, is_active, created_at, preferred_language, user_roles(role_id, roles(id, name, role_permissions(permissions(key, name))))",
        )
        .eq("id", userId)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
  });

  const { data: roles } = useQuery({
    queryKey: ["roles-simple"],
    enabled: can("users.manage_roles"),
    queryFn: async () => {
      const { data, error } = await supabase.from("roles").select("id, name").order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: documents } = useQuery({
    queryKey: ["staff-docs", userId],
    enabled: can("users.view"),
    queryFn: () => getUserDocuments({ data: { user_id: userId } }),
  });

  const { data: salary } = useQuery({
    queryKey: ["staff-salary", userId],
    enabled: can("payroll.view"),
    queryFn: async () => {
      const { data } = await supabase
        .from("employee_salaries")
        .select("base_salary, effective_from, is_active")
        .eq("user_id", userId)
        .eq("is_active", true)
        .maybeSingle();
      return data;
    },
  });

  const { data: attendance } = useQuery({
    queryKey: ["staff-attendance", userId],
    queryFn: async () => {
      const { data } = await supabase
        .from("attendance")
        .select("work_date, status")
        .eq("user_id", userId)
        .order("work_date", { ascending: false })
        .limit(10);
      return data ?? [];
    },
  });

  useEffect(() => {
    if (!profile) return;
    setRoleIds((profile.user_roles ?? []).map((row) => row.role_id));
  }, [profile]);

  const saveRoles = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("set_user_roles", {
        _user_id: userId,
        _role_ids: roleIds,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["staff", userId] });
      queryClient.invalidateQueries({ queryKey: ["users"] });
      toast.success(lang === "ar" ? "تم حفظ الأدوار." : "Roles saved.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const replaceDoc = useMutation({
    mutationFn: async (input: { kind: "id_front" | "id_back"; file: File }) => {
      const payload = await fileToPayload(input.file);
      await uploadUserDocument({ data: { user_id: userId, kind: input.kind, file: payload } });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["staff-docs", userId] });
      toast.success(t("common.saved"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });
  const removeDoc = useMutation({
    mutationFn: (docId: string) => deleteUserDocument({ data: { doc_id: docId } }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["staff-docs", userId] });
      toast.success(lang === "ar" ? "تم حذف المرفق" : "Attachment removed");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!can("users.view")) return <NoPermission message={t("common.noAccess")} />;
  if (!profile) return <p className="text-sm text-muted-foreground">{t("common.loading")}</p>;

  const roleLabel = (name: string) => {
    const key = `role.${name}`;
    const label = t(key);
    return label === key ? name : label;
  };
  const permissions = [
    ...new Set(
      (profile.user_roles ?? []).flatMap((row) =>
        (row.roles?.role_permissions ?? []).map((rp) => rp.permissions?.key ?? ""),
      ),
    ),
  ]
    .filter(Boolean)
    .sort();
  const docFor = (kind: string) => (documents ?? []).find((doc) => doc.kind === kind);

  return (
    <div className="space-y-4">
      <PageHeader
        title={profile.display_name || `${profile.first_name} ${profile.last_name ?? ""}`.trim()}
        description={t("users.details")}
        action={
          <div className="flex flex-wrap items-center gap-2">
            {can("users.update") && (
              <EmployeeEditDialog userId={userId} isSelf={userId === me?.profile.id} showLabel />
            )}
            {isSuperAdmin &&
              userId !== me?.profile.id &&
              (profile.email ?? "").toLowerCase() !== ROOT_ADMIN_EMAIL && (
                <AlertDialog>
                  <AlertDialogTrigger asChild>
                    <Button size="sm" variant="outline" className="border-destructive/40 text-destructive">
                      <Trash2 className="size-4" />
                      {lang === "ar" ? "حذف الموظف" : "Delete"}
                    </Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>{t("users.deleteTitle")}</AlertDialogTitle>
                      <AlertDialogDescription>
                        {lang === "ar"
                          ? "لو الموظف ليه ورديات أو طلبات أو رواتب، هيتأرشف ويتقفل دخوله مع حفظ كل سجلاته بدل الحذف النهائي."
                          : "If the employee has shifts, orders or payroll, they are archived and blocked from signing in, with all records kept."}
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
                      <AlertDialogAction
                        className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                        disabled={removeEmployee.isPending}
                        onClick={() => removeEmployee.mutate()}
                      >
                        {t("users.delete")}
                      </AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              )}
            <Button variant="outline" size="sm" asChild>
              <Link to="/hr" search={{ tab: "team" }}>
                <ArrowLeft className="size-4 rtl:rotate-180" />
                {t("users.back")}
              </Link>
            </Button>
          </div>
        }
      />

      <div className="grid gap-4 lg:grid-cols-2 stagger">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{t("users.contact")}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <Row label={t("users.email")} value={profile.email || t("users.noLogin")} />
            <Row label={t("users.phone")} value={profile.phone || "—"} />
            <Row label={t("users.code")} value={profile.employee_code || "—"} />
            <Row
              label={t("common.status")}
              value={profile.is_active ? t("common.active") : t("common.inactive")}
            />
            <Row
              label={t("users.joined")}
              value={new Date(profile.created_at).toLocaleDateString(
                lang === "ar" ? "ar-EG" : "en-GB",
              )}
            />
            {can("payroll.view") && (
              <Row label={t("users.salary")} value={salary ? String(salary.base_salary) : "—"} />
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">{t("users.roles")}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <p className="text-xs text-muted-foreground">{t("users.multiRoleHint")}</p>
            <div className="grid gap-2 sm:grid-cols-2">
              {(roles ?? []).map((role) => (
                <label
                  key={role.id}
                  className="flex items-center gap-2 rounded-md border border-border/60 bg-background/60 p-2 text-sm"
                >
                  <Checkbox
                    disabled={!can("users.manage_roles")}
                    checked={roleIds.includes(role.id)}
                    onCheckedChange={(value) =>
                      setRoleIds((prev) =>
                        value === true ? [...prev, role.id] : prev.filter((id) => id !== role.id),
                      )
                    }
                  />
                  {roleLabel(role.name)}
                </label>
              ))}
            </div>
            {can("users.manage_roles") && (
              <Button onClick={() => saveRoles.mutate()} disabled={saveRoles.isPending}>
                {t("users.saveRoles")}
              </Button>
            )}
            <div>
              <p className="mb-1 text-xs font-bold uppercase tracking-wide text-muted-foreground">
                {t("users.permissions")}
              </p>
              <div className="flex flex-wrap gap-1">
                {permissions.map((key) => (
                  <Badge key={key} variant="outline" className="font-mono text-[10px]">
                    {key}
                  </Badge>
                ))}
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">{t("users.documents")}</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-2">
            {(["id_front", "id_back"] as const).map((kind) => {
              const doc = docFor(kind);
              return (
                <div key={kind} className="space-y-2">
                  <Label>{kind === "id_front" ? t("users.idFront") : t("users.idBack")}</Label>
                  {doc?.url ? (
                    <div className="space-y-2">
                      <ImageThumb
                        src={doc.url}
                        alt={kind === "id_front" ? t("users.idFront") : t("users.idBack")}
                        className="h-36 w-full"
                      />
                      {can("users.update") && (
                        <Button size="sm" variant="destructive" disabled={removeDoc.isPending} onClick={() => doc.id && removeDoc.mutate(doc.id)}>
                          <Trash2 className="size-4" />
                          {lang === "ar" ? "حذف المرفق" : "Remove attachment"}
                        </Button>
                      )}
                    </div>
                  ) : (
                    <p className="rounded-lg border border-dashed border-border p-6 text-center text-xs text-muted-foreground">
                      {t("users.noDocuments")}
                    </p>
                  )}
                  {can("users.update") && (
                    <Input
                      type="file"
                      accept="image/*,application/pdf"
                      onChange={(event) => {
                        const file = event.target.files?.[0];
                        if (file) replaceDoc.mutate({ kind, file });
                      }}
                    />
                  )}
                </div>
              );
            })}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">{t("users.attendance")}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            {(attendance ?? []).length === 0 ? (
              <p className="text-muted-foreground">—</p>
            ) : (
              (attendance ?? []).map((row) => (
                <div
                  key={row.work_date}
                  className="flex items-center justify-between rounded-md border border-border/50 px-3 py-2 even:bg-muted/25"
                >
                  <span>{row.work_date}</span>
                  <span className="text-muted-foreground">
                    {t(ATTENDANCE_STATUS_KEYS[row.status] ?? row.status)}
                  </span>
                </div>
              ))
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 border-b border-border/40 py-1.5 last:border-0">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium">{value}</span>
    </div>
  );
}
