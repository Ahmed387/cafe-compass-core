import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { ChevronRight, IdCard, Trash2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
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
import {
  createCompanyUser,
  createEmployeeRecord,
  deleteCompanyUser,
  setUserActive,
} from "@/lib/admin.functions";
import { ROOT_ADMIN_EMAIL, useAuth } from "@/lib/auth";
import { EmployeeEditDialog } from "@/modules/governance/EmployeeEditDialog";
import { UserAccessDialog } from "@/modules/governance/UserAccessDialog";
import { fileToPayload, MAX_UPLOAD_BYTES } from "@/lib/files";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type UserRow = {
  id: string;
  display_name: string | null;
  first_name: string;
  last_name: string | null;
  email: string | null;
  phone: string | null;
  employee_code: string | null;
  is_active: boolean;
  archived_at: string | null;
  created_at: string;
  user_roles: Array<{ roles: { name: string } | null }> | null;
};

export function UsersPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const isSuperAdmin = me?.roleNames.includes("Super Admin") ?? false;
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [statusView, setStatusView] = useState<"active" | "archived">("active");
  const [hasLogin, setHasLogin] = useState(true);
  const [deleteTarget, setDeleteTarget] = useState<UserRow | null>(null);
  const [idFront, setIdFront] = useState<File | null>(null);
  const [idBack, setIdBack] = useState<File | null>(null);
  const [form, setForm] = useState({
    email: "",
    password: "",
    first_name: "",
    last_name: "",
    phone: "",
    employee_code: "",
    role_ids: [] as string[],
    branch_ids: [] as string[],
  });

  const { data: users } = useQuery({
    queryKey: ["users"],
    enabled: can("users.view"),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("user_profiles")
        .select(
          "id, display_name, first_name, last_name, email, phone, employee_code, is_active, archived_at, created_at, user_roles(roles(name))",
        )
        .order("created_at");
      if (error) throw error;
      return (data ?? []) as unknown as UserRow[];
    },
  });

  const { data: roles } = useQuery({
    queryKey: ["roles-simple"],
    enabled: can("users.create"),
    queryFn: async () => {
      const { data, error } = await supabase.from("roles").select("id, name").order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: branches } = useQuery({
    queryKey: ["branches-simple"],
    enabled: can("users.create"),
    queryFn: async () => {
      const { data, error } = await supabase.from("branches").select("id, name").order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const create = useMutation({
    mutationFn: async () => {
      if (!idFront || !idBack) throw new Error(t("users.idRequired"));
      if (idFront.size > MAX_UPLOAD_BYTES || idBack.size > MAX_UPLOAD_BYTES) {
        throw new Error(
          lang === "ar" ? "حجم الصورة أكبر من ٥ ميجا." : "Image is larger than 5 MB.",
        );
      }
      const list = branches ?? [];
      const only = list.length === 1 ? list[0] : undefined;
      const branchIds = only ? [only.id] : form.branch_ids;
      const [front, back] = await Promise.all([fileToPayload(idFront), fileToPayload(idBack)]);
      if (!hasLogin) {
        await createEmployeeRecord({
          data: {
            first_name: form.first_name,
            last_name: form.last_name,
            phone: form.phone,
            employee_code: form.employee_code,
            id_front: front,
            id_back: back,
          },
        });
        return;
      }
      await createCompanyUser({
        data: { ...form, branch_ids: branchIds, id_front: front, id_back: back },
      });
    },

    onSuccess: () => {
      setOpen(false);
      setIdFront(null);
      setIdBack(null);
      setForm({
        email: "",
        password: "",
        first_name: "",
        last_name: "",
        phone: "",
        employee_code: "",
        role_ids: [],
        branch_ids: [],
      });
      queryClient.invalidateQueries({ queryKey: ["users"] });
      toast.success(lang === "ar" ? "تم إنشاء المستخدم." : "User created.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const toggle = useMutation({
    mutationFn: async (user: { id: string; is_active: boolean }) => {
      await setUserActive({ data: { user_id: user.id, is_active: !user.is_active } });
    },
    onSuccess: (_d, user) => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
      toast.success(
        user.is_active
          ? lang === "ar" ? "تم تعطيل المستخدم." : "User disabled."
          : lang === "ar" ? "تم تفعيل المستخدم." : "User enabled.",
      );
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const remove = useMutation({
    mutationFn: async (userId: string) => {
      return deleteCompanyUser({ data: { user_id: userId } });
    },
    onSuccess: (res) => {
      setDeleteTarget(null);
      queryClient.invalidateQueries({ queryKey: ["users"] });
      if (res.mode === "archived") {
        toast.success(
          lang === "ar"
            ? "لهذا المستخدم سجلات تشغيلية (ورديات/طلبات/رواتب)، لذلك تمت أرشفته وتعطيله بأمان بدل الحذف النهائي. سجلاته محفوظة."
            : "This user has operational history (shifts/orders/payroll), so they were safely archived and disabled instead of deleted. Their records are kept.",
        );
      } else toast.success(t("users.deleted"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!can("users.view")) return <NoPermission message={t("common.noAccess")} />;

  const roleLabel = (name: string) => {
    const key = `role.${name}`;
    const label = t(key);
    return label === key ? name : label;
  };
  const initials = (user: UserRow) =>
    (user.display_name || user.first_name || "?")
      .split(" ")
      .map((part) => part[0])
      .slice(0, 2)
      .join("")
      .toUpperCase();
  const shownUsers = (users ?? []).filter((user) =>
    statusView === "active" ? user.is_active && !user.archived_at : !user.is_active || Boolean(user.archived_at),
  );

  return (
    <div>
      <PageHeader
        title={t("users.title")}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <div className="inline-flex rounded-lg border border-border bg-card p-1">
              <Button size="sm" variant={statusView === "active" ? "default" : "ghost"} onClick={() => setStatusView("active")}>
                {lang === "ar" ? "النشطون" : "Active"}
              </Button>
              <Button size="sm" variant={statusView === "archived" ? "default" : "ghost"} onClick={() => setStatusView("archived")}>
                {lang === "ar" ? "المعطلون / الأرشيف" : "Inactive / archived"}
              </Button>
            </div>
            {can("users.create") && (
            <Dialog open={open} onOpenChange={setOpen}>
              <DialogTrigger asChild>
                <Button>{t("users.new")}</Button>
              </DialogTrigger>
              <DialogContent className="max-h-[85vh] overflow-y-auto">
                <DialogHeader>
                  <DialogTitle>{t("users.new")}</DialogTitle>
                </DialogHeader>
                <div className="space-y-3">
                  <label className="flex items-start gap-2 rounded-md border border-border/60 bg-background/60 p-3 text-sm">
                    <Checkbox
                      checked={hasLogin}
                      onCheckedChange={(value) => setHasLogin(value === true)}
                    />
                    <span className="leading-tight">
                      <span className="block font-medium">{t("users.hasLogin")}</span>
                      <span className="block text-xs text-muted-foreground">
                        {t("users.hasLoginHint")}
                      </span>
                    </span>
                  </label>

                  <div className="grid gap-3 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label>{t("users.firstName")}</Label>
                      <Input
                        value={form.first_name}
                        onChange={(event) => setForm({ ...form, first_name: event.target.value })}
                      />
                    </div>
                    <div className="space-y-2">
                      <Label>{t("users.lastName")}</Label>
                      <Input
                        value={form.last_name}
                        onChange={(event) => setForm({ ...form, last_name: event.target.value })}
                      />
                    </div>
                  </div>
                  <div className="grid gap-3 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label>{t("users.phone")}</Label>
                      <Input
                        value={form.phone}
                        onChange={(event) => setForm({ ...form, phone: event.target.value })}
                      />
                    </div>
                    <div className="space-y-2">
                      <Label>{t("users.code")}</Label>
                      <Input
                        value={form.employee_code}
                        onChange={(event) =>
                          setForm({ ...form, employee_code: event.target.value })
                        }
                      />
                    </div>
                  </div>
                  {hasLogin && (
                    <>
                      <div className="space-y-2">
                        <Label>{t("auth.email")}</Label>
                        <Input
                          type="email"
                          value={form.email}
                          onChange={(event) => setForm({ ...form, email: event.target.value })}
                        />
                      </div>
                      <div className="space-y-2">
                        <Label>{t("users.tempPassword")}</Label>
                        <Input
                          type="text"
                          value={form.password}
                          onChange={(event) => setForm({ ...form, password: event.target.value })}
                        />
                      </div>
                      <div className="space-y-2">
                        <Label>{t("users.roles")}</Label>
                        <p className="text-xs text-muted-foreground">{t("users.multiRoleHint")}</p>
                        <div className="grid gap-2 sm:grid-cols-2">
                          {(roles ?? []).map((role) => (
                            <label
                              key={role.id}
                              className="flex items-center gap-2 rounded-md border border-border/60 bg-background/60 p-2 text-sm transition-colors hover:bg-secondary/60"
                            >
                              <Checkbox
                                checked={form.role_ids.includes(role.id)}
                                onCheckedChange={(value) =>
                                  setForm({
                                    ...form,
                                    role_ids:
                                      value === true
                                        ? [...form.role_ids, role.id]
                                        : form.role_ids.filter((id) => id !== role.id),
                                  })
                                }
                              />
                              {roleLabel(role.name)}
                            </label>
                          ))}
                        </div>
                      </div>
                    </>
                  )}

                  <div className="grid gap-3 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label>
                        {t("users.idFront")} <span className="text-destructive">*</span>
                      </Label>
                      <Input
                        type="file"
                        accept="image/*,application/pdf"
                        onChange={(event) => setIdFront(event.target.files?.[0] ?? null)}
                      />
                    </div>
                    <div className="space-y-2">
                      <Label>
                        {t("users.idBack")} <span className="text-destructive">*</span>
                      </Label>
                      <Input
                        type="file"
                        accept="image/*,application/pdf"
                        onChange={(event) => setIdBack(event.target.files?.[0] ?? null)}
                      />
                    </div>
                  </div>
                  {(branches ?? []).length > 1 && (
                    <div className="space-y-2">
                      <Label>{t("users.branches")}</Label>
                      <div className="grid gap-2 sm:grid-cols-2">
                        {(branches ?? []).map((branch) => (
                          <label key={branch.id} className="flex items-center gap-2 text-sm">
                            <Checkbox
                              checked={form.branch_ids.includes(branch.id)}
                              onCheckedChange={(value) =>
                                setForm({
                                  ...form,
                                  branch_ids:
                                    value === true
                                      ? [...form.branch_ids, branch.id]
                                      : form.branch_ids.filter((id) => id !== branch.id),
                                })
                              }
                            />
                            {branch.name}
                          </label>
                        ))}
                      </div>
                    </div>
                  )}
                </div>
                <DialogFooter>
                  <Button
                    onClick={() => create.mutate()}
                    disabled={
                      create.isPending ||
                      !form.first_name ||
                      !idFront ||
                      !idBack ||
                      (hasLogin && (!form.email || form.password.length < 8))
                    }
                  >
                    {t("common.create")}
                  </Button>
                </DialogFooter>
              </DialogContent>
            </Dialog>
            )}
          </div>
        }
      />

      {!users || shownUsers.length === 0 ? (
        <EmptyState message={t("users.empty")} />
      ) : (
        <div className="card-surface overflow-hidden rounded-xl border">
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow className="bg-secondary/60 hover:bg-secondary/60">
                  <TableHead className="text-start">{t("common.name")}</TableHead>
                  <TableHead className="text-start">{t("auth.email")}</TableHead>
                  <TableHead className="text-start">{t("users.code")}</TableHead>
                  <TableHead className="text-start">{t("users.roles")}</TableHead>
                  <TableHead className="text-center">{t("common.status")}</TableHead>
                  <TableHead className="text-end">{t("common.actions")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {shownUsers.map((user, index) => (
                  <TableRow
                    key={user.id}
                    style={{ animationDelay: `${index * 25}ms` }}
                    onClick={() => navigate({ to: "/staff/$userId", params: { userId: user.id } })}
                    className="cursor-pointer border-border/60 transition-colors even:bg-muted/25 hover:bg-primary/5"
                  >
                    <TableCell className="whitespace-nowrap">
                      <span className="flex items-center gap-3">
                        <span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-gradient-brand text-xs font-bold text-primary-foreground">
                          {initials(user)}
                        </span>
                        <span className="leading-tight">
                          <span className="block font-semibold">
                            {user.display_name ||
                              `${user.first_name} ${user.last_name ?? ""}`.trim()}
                          </span>
                          <span className="block text-xs text-muted-foreground">
                            {user.phone || "—"}
                          </span>
                        </span>
                      </span>
                    </TableCell>
                    <TableCell className="whitespace-nowrap text-muted-foreground">
                      {user.email ?? (
                        <Badge variant="outline" className="text-muted-foreground">
                          {t("users.noLogin")}
                        </Badge>
                      )}
                    </TableCell>

                    <TableCell className="whitespace-nowrap font-mono text-xs text-muted-foreground">
                      {user.employee_code || "—"}
                    </TableCell>
                    <TableCell>
                      <span className="flex flex-wrap gap-1">
                        {(user.user_roles ?? []).length === 0 ? (
                          <span className="text-xs text-muted-foreground">—</span>
                        ) : (
                          (user.user_roles ?? []).map((row, i) => (
                            <Badge
                              key={i}
                              variant="secondary"
                              className="border border-primary/20 bg-primary/10 text-primary"
                            >
                              {roleLabel(row.roles?.name ?? "")}
                            </Badge>
                          ))
                        )}
                      </span>
                    </TableCell>
                    <TableCell className="text-center">
                      <Badge
                        className={
                          user.is_active
                            ? "border border-success/30 bg-success/15 text-success"
                            : "border border-border bg-muted text-muted-foreground"
                        }
                      >
                        {user.is_active ? t("common.active") : t("common.inactive")}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-end">
                      <span
                        className="flex items-center justify-end gap-2"
                        onClick={(event) => event.stopPropagation()}
                      >
                        {can("users.disable") && (
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() =>
                              toggle.mutate({ id: user.id, is_active: user.is_active })
                            }
                          >
                            {user.is_active ? t("common.disable") : t("common.enable")}
                          </Button>
                        )}
                        {can("users.update") && (
                          <EmployeeEditDialog userId={user.id} isSelf={user.id === me?.profile.id} />
                        )}
                        {isSuperAdmin && (
                          <UserAccessDialog
                            profileId={user.id}
                            name={user.display_name || user.first_name}
                            isSuper={(user.user_roles ?? []).some((r) => r.roles?.name === "Super Admin")}
                            isRootTarget={user.email?.toLowerCase() === ROOT_ADMIN_EMAIL}
                          />
                        )}
                        {isSuperAdmin &&
                          user.id !== me?.profile.id &&
                          user.email?.toLowerCase() !== ROOT_ADMIN_EMAIL && (
                          <Button
                            size="sm"
                            variant="outline"
                            className="border-destructive/40 text-destructive hover:bg-destructive/10 hover:text-destructive"
                            onClick={() => setDeleteTarget(user)}
                          >
                            <Trash2 className="size-4" />
                            <span className="sr-only">{t("users.delete")}</span>
                          </Button>
                        )}
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() =>
                            navigate({ to: "/staff/$userId", params: { userId: user.id } })
                          }
                        >
                          <IdCard className="size-4" />
                          <ChevronRight className="size-4 rtl:rotate-180" />
                        </Button>
                      </span>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </div>
      )}

      <Dialog open={deleteTarget !== null} onOpenChange={(next) => !next && setDeleteTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("users.deleteTitle")}</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">{t("users.deleteConfirm")}</p>
          <p className="rounded-lg border border-border bg-muted/40 p-3 text-xs text-muted-foreground">
            {lang === "ar"
              ? "إذا كان للمستخدم سجلات (ورديات، طلبات، رواتب، حركات مالية) فلن يُحذف نهائيًا، بل يُؤرشف ويُعطَّل ويُمنع من الدخول مع حفظ كل سجلاته."
              : "If the user has records (shifts, orders, payroll, cash movements) they won't be permanently deleted — they'll be archived, disabled and blocked from signing in, with all records kept."}
          </p>
          {deleteTarget && (
            <p className="text-sm font-semibold">
              {deleteTarget.display_name || deleteTarget.first_name} — {deleteTarget.email}
            </p>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteTarget(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={remove.isPending}
              onClick={() => deleteTarget && remove.mutate(deleteTarget.id)}
            >
              {t("users.delete")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
