import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Check, LockKeyhole, X } from "lucide-react";
import { toast } from "sonner";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
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
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/roles")({
  head: () => ({
    meta: [
      { title: "Permission matrix — 20s Coffee" },
      { name: "description", content: "Control critical actions for Super Admin, Manager and Cashier." },
      { property: "og:title", content: "Permission matrix — 20s Coffee" },
      { property: "og:description", content: "A secure critical-action permission matrix." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: RolesPage,
});

type RoleRow = {
  id: string;
  name: string;
  role_permissions: Array<{ permissions: { key: string } | null }> | null;
};

const ROLE_NAMES = ["Super Admin", "Manager", "Cashier"] as const;
const ACTIONS = [
  { key: "products.view_cost", ar: "عرض تكلفة المنتجات", en: "View product costs" },
  { key: "reports.profit", ar: "عرض الأرباح", en: "View profit reports" },
  { key: "shifts.adjust_cash", ar: "فتح / تعديل الدرج يدويًا", en: "Open / adjust drawer manually" },
  { key: "inventory.adjust", ar: "اعتماد الجرد", en: "Approve stocktakes" },
  { key: "purchases.create", ar: "إنشاء المشتريات", en: "Create purchases" },
  { key: "inventory.emergency_transfer", ar: "النقل الطارئ إلى البار", en: "Emergency bar transfers" },
] as const;

function RolesPage() {
  const { lang } = useI18n();
  const { can, me } = useAuth();
  const queryClient = useQueryClient();
  const ar = lang === "ar";

  const roles = useQuery({
    queryKey: ["critical-permission-matrix"],
    enabled: can("users.manage_roles"),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("roles")
        .select("id,name,role_permissions(permissions(key))")
        .in("name", [...ROLE_NAMES]);
      if (error) throw error;
      return (data ?? []) as unknown as RoleRow[];
    },
  });

  const toggle = useMutation({
    mutationFn: async (input: { roleId: string; permissionKey: string; enabled: boolean }) => {
      const { error } = await supabase.rpc("set_role_permission", {
        _role_id: input.roleId,
        _permission_key: input.permissionKey,
        _enabled: input.enabled,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["critical-permission-matrix"] });
      queryClient.invalidateQueries({ queryKey: ["me"] });
      toast.success(ar ? "تم تحديث الصلاحية." : "Permission updated.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (!can("users.manage_roles")) {
    return <NoPermission message={ar ? "ليس لديك صلاحية لهذه الصفحة." : "You cannot access this page."} />;
  }

  const ordered = ROLE_NAMES.map((name) => roles.data?.find((role) => role.name === name)).filter(
    (role): role is RoleRow => Boolean(role),
  );
  const enabled = (role: RoleRow, key: string) =>
    (role.role_permissions ?? []).some((row) => row.permissions?.key === key);

  return (
    <div>
      <PageHeader
        title={ar ? "مصفوفة الصلاحيات الحرجة" : "Critical permission matrix"}
        description={
          ar
            ? "تحكم مباشر في الإجراءات التشغيلية الحساسة لكل دور. كل تغيير محفوظ في سجل المراجعة."
            : "Direct control of sensitive operational actions. Every change is audit logged."
        }
      />

      <div className="overflow-x-auto rounded-lg border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow className="bg-secondary/60 hover:bg-secondary/60">
              <TableHead className="min-w-64 text-start">{ar ? "الإجراء" : "Action"}</TableHead>
              {ordered.map((role) => (
                <TableHead key={role.id} className="min-w-36 text-center">
                  <span className="inline-flex items-center gap-2">
                    {role.name === "Super Admin" && <LockKeyhole className="size-4 text-primary" />}
                    {role.name}
                  </span>
                </TableHead>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {ACTIONS.map((action) => (
              <TableRow key={action.key}>
                <TableCell>
                  <span className="block font-medium">{ar ? action.ar : action.en}</span>
                </TableCell>
                {ordered.map((role) => {
                  const checked = enabled(role, action.key);
                  const locked = role.name === "Super Admin" && !me?.isRoot;
                  return (
                    <TableCell key={role.id} className="text-center">
                      <div className="inline-flex items-center gap-2">
                        <Switch
                          checked={checked}
                          disabled={locked || toggle.isPending}
                          aria-label={`${action.en} — ${role.name}`}
                          onCheckedChange={(next) =>
                            toggle.mutate({ roleId: role.id, permissionKey: action.key, enabled: next })
                          }
                        />
                        <Badge variant={checked ? "default" : "outline"} className="min-w-8 justify-center px-1">
                          {checked ? <Check className="size-3" /> : <X className="size-3" />}
                        </Badge>
                      </div>
                    </TableCell>
                  );
                })}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}