import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useMemo, useState } from "react";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
import { auditLabels } from "@/lib/audit-labels";
import { formatDateTime } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/audit")({
  head: () => ({
    meta: [
      { title: "Audit log — 20s Coffee" },
      { name: "description", content: "Append-only trail of sensitive actions in the system." },
      { property: "og:title", content: "Audit log — 20s Coffee" },
      { property: "og:description", content: "Append-only trail of sensitive system actions." },
    ],
  }),
  component: AuditPage,
});

function AuditPage() {
  const { t, lang } = useI18n();
  const { can } = useAuth();
  const [search, setSearch] = useState("");
  const [moduleFilter, setModuleFilter] = useState("all");

  const { data } = useQuery({
    queryKey: ["audit-logs"],
    enabled: can("audit.view"),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("audit_logs")
        .select(
          "id, action, module, entity_type, entity_id, created_at, reason, user_id, user_profiles(display_name, first_name, last_name)",
        )
        .order("created_at", { ascending: false })
        .limit(200);
      if (error) throw error;
      return data ?? [];
    },
  });

  const rows = useMemo(() => data ?? [], [data]);

  const labels = auditLabels(t);
  const actionLabel = labels.action;
  const moduleLabel = labels.module;
  const entityLabel = labels.entity;
  const toneOf = labels.tone;
  const userLabel = (row: (typeof rows)[number]) => {
    const profile = row.user_profiles;
    if (!profile) return t("audit.system");
    return (
      profile.display_name ||
      [profile.first_name, profile.last_name].filter(Boolean).join(" ") ||
      t("audit.system")
    );
  };

  const modules = useMemo(() => Array.from(new Set(rows.map((r) => r.module))).sort(), [rows]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (moduleFilter !== "all" && row.module !== moduleFilter) return false;
      if (!q) return true;
      return [
        actionLabel(row.action),
        row.action,
        moduleLabel(row.module),
        userLabel(row),
        row.entity_type ?? "",
        row.entity_id ?? "",
        row.reason ?? "",
      ]
        .join(" ")
        .toLowerCase()
        .includes(q);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, search, moduleFilter, lang]);

  if (!can("audit.view")) return <NoPermission message={t("common.noAccess")} />;

  return (
    <div className="animate-fade-in">
      <PageHeader title={t("audit.title")} description={t("audit.subtitle")} />

      {rows.length === 0 ? (
        <EmptyState message={t("audit.empty")} />
      ) : (
        <>
          <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center">
            <Input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t("audit.search")}
              className="sm:max-w-sm"
            />
            <Select value={moduleFilter} onValueChange={setModuleFilter}>
              <SelectTrigger className="sm:w-52">
                <SelectValue placeholder={t("audit.allModules")} />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">{t("audit.allModules")}</SelectItem>
                {modules.map((m) => (
                  <SelectItem key={m} value={m}>
                    {moduleLabel(m)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <span className="text-sm text-muted-foreground sm:ms-auto">
              {filtered.length} {t("audit.rows")}
            </span>
          </div>

          {filtered.length === 0 ? (
            <EmptyState message={t("audit.noMatch")} />
          ) : (
            <div className="overflow-x-auto rounded-xl border border-border bg-card shadow-sm">
              <Table className="text-sm">
                <TableHeader>
                  <TableRow className="bg-muted/50">
                    <TableHead className="w-48 text-start font-semibold">
                      {t("common.date")}
                    </TableHead>
                    <TableHead className="w-40 text-start font-semibold">
                      {t("audit.user")}
                    </TableHead>
                    <TableHead className="w-56 text-start font-semibold">
                      {t("audit.action")}
                    </TableHead>
                    <TableHead className="w-32 text-start font-semibold">
                      {t("audit.module")}
                    </TableHead>
                    <TableHead className="w-56 whitespace-nowrap text-start font-semibold">
                      {t("audit.entity")}
                    </TableHead>
                    <TableHead className="min-w-56 whitespace-nowrap text-start font-semibold">
                      {t("audit.reason")}
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {filtered.map((row) => (
                    <TableRow key={row.id} className="transition-colors hover:bg-muted/40">
                      <TableCell className="whitespace-nowrap align-middle text-start tabular-nums text-muted-foreground">
                        {formatDateTime(row.created_at, lang)}
                      </TableCell>
                      <TableCell className="align-middle text-start font-medium">
                        {userLabel(row)}
                      </TableCell>
                      <TableCell className="align-middle text-start">
                        <Badge variant={toneOf(row.action)} className="whitespace-nowrap">
                          {actionLabel(row.action)}
                        </Badge>
                      </TableCell>
                      <TableCell className="align-middle text-start text-muted-foreground">
                        {moduleLabel(row.module)}
                      </TableCell>
                      <TableCell className="whitespace-nowrap align-middle text-start font-mono text-xs text-muted-foreground">
                        {entityLabel(row.entity_type, row.entity_id)}
                      </TableCell>
                      <TableCell className="min-w-56 align-middle text-start text-muted-foreground">
                        {row.reason ?? "—"}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
