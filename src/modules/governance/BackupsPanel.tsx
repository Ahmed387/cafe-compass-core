import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import {
  CloudUpload,
  ExternalLink,
  HardDriveDownload,
  Loader2,
  RotateCcw,
  Trash2,
} from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

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
import { supabase } from "@/integrations/supabase/client";
import type { Json } from "@/integrations/supabase/types";
import { useAuth } from "@/lib/auth";
import {
  deleteBackup,
  downloadSnapshot,
  fetchBackupPayload,
  runBackupNow,
} from "@/lib/backup.functions";
import { downloadJson, stampedName } from "@/lib/csv";
import { formatDateTime, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type BackupRow = {
  id: string;
  status: string;
  file_name: string | null;
  file_size_bytes: number | null;
  drive_file_id: string | null;
  drive_link: string | null;
  drive_folder_id: string | null;
  error_message: string | null;
  created_at: string;
};

const RESTORE_TEXT = "RESTORE-20S";

function sizeLabel(bytes: number | null) {
  if (!bytes) return "—";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

/** Super-admin overview of automated backups plus a manual trigger. */
export function BackupsPanel() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const queryClient = useQueryClient();
  const runBackup = useServerFn(runBackupNow);
  const getSnapshot = useServerFn(downloadSnapshot);
  const removeBackup = useServerFn(deleteBackup);
  const getPayload = useServerFn(fetchBackupPayload);
  const [pendingDelete, setPendingDelete] = useState<BackupRow | null>(null);
  const [restoreOpen, setRestoreOpen] = useState(false);
  const [restoreConfirm, setRestoreConfirm] = useState("");
  const [restoreName, setRestoreName] = useState("");
  const [restorePayload, setRestorePayload] = useState<Record<string, Json> | null>(null);

  const isSuperAdmin = useQuery({
    queryKey: ["is-super-admin"],
    enabled: Boolean(me),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("is_super_admin");
      if (error) throw error;
      return Boolean(data);
    },
  });

  const history = useQuery({
    queryKey: ["backup-history"],
    enabled: isSuperAdmin.data === true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("backup_history")
        .select(
          "id, status, file_name, file_size_bytes, drive_file_id, drive_link, drive_folder_id, error_message, created_at",
        )
        .order("created_at", { ascending: false })
        .limit(10);
      if (error) throw error;
      return (data ?? []) as BackupRow[];
    },
  });

  const run = useMutation({
    mutationFn: async () => runBackup({ data: undefined }),
    onSuccess: (result) => {
      queryClient.invalidateQueries({ queryKey: ["backup-history"] });
      if (result.status === "success") {
        toast.success(
          result.uploaded
            ? ar
              ? `تم رفع ${result.file_name} إلى مجلد 20s على جوجل درايف.`
              : `Uploaded ${result.file_name} to the 20s folder on Google Drive.`
            : ar
              ? "تم إنشاء النسخة لكن جوجل درايف غير متصل."
              : "Backup created but Google Drive is not connected.",
        );
      } else {
        toast.error(result.error_message ?? (ar ? "فشل إنشاء النسخة." : "Backup failed."));
      }
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const snapshot = useMutation({
    mutationFn: async () => getSnapshot({ data: undefined }),
    onSuccess: (data) => {
      downloadJson(data, stampedName("financial-snapshot", "json"));
      toast.success(ar ? "تم تنزيل النسخة." : "Snapshot downloaded.");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const remove = useMutation({
    mutationFn: async (id: string) => removeBackup({ data: { id } }),
    onSuccess: () => {
      setPendingDelete(null);
      queryClient.invalidateQueries({ queryKey: ["backup-history"] });
      toast.success(ar ? "تم حذف النسخة الاحتياطية بنجاح" : "Backup deleted successfully");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : friendlyError(error, lang)),
  });

  const restore = useMutation({
    mutationFn: async () => {
      if (!restorePayload) throw new Error(ar ? "اختار ملف نسخة أولاً." : "Pick a snapshot first.");
      const { data, error } = await supabase.rpc("restore_backup_snapshot", {
        p_payload: restorePayload,
        p_confirm: RESTORE_TEXT,
      });
      if (error) throw new Error(error.message);
      return data;
    },
    onSuccess: () => {
      setRestoreOpen(false);
      setRestoreConfirm("");
      setRestorePayload(null);
      setRestoreName("");
      queryClient.invalidateQueries();
      toast.success(ar ? "تمت استعادة النسخة بنجاح." : "Snapshot restored successfully.");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : friendlyError(error, lang)),
  });

  const pullFromDrive = useMutation({
    mutationFn: async (row: BackupRow) => getPayload({ data: { id: row.id } }),
    onSuccess: (result) => {
      setRestorePayload(result.payload);
      setRestoreName(result.file_name ?? "");
      toast.success(ar ? "تم تحميل النسخة من درايف." : "Snapshot loaded from Drive.");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : friendlyError(error, lang)),
  });

  async function readLocalFile(file: File) {
    try {
      const parsed = JSON.parse(await file.text()) as Record<string, Json>;
      setRestorePayload(parsed);
      setRestoreName(file.name);
    } catch {
      toast.error(ar ? "الملف مش JSON صحيح." : "That file is not valid JSON.");
    }
  }

  if (isSuperAdmin.data !== true) return null;

  const last = history.data?.[0];

  return (
    <Card className="mt-4 animate-fade-in">
      <CardHeader className="flex flex-row flex-wrap items-center justify-between gap-3">
        <CardTitle className="text-base">{ar ? "النسخ الاحتياطي" : "Backups"}</CardTitle>
        <div className="flex flex-wrap gap-2">
          <Button
            variant="outline"
            size="sm"
            className="gap-2"
            disabled={snapshot.isPending}
            onClick={() => snapshot.mutate()}
          >
            <HardDriveDownload className="h-4 w-4" />
            {ar ? "تنزيل نسخة JSON" : "Download JSON"}
          </Button>
          <Button
            variant="outline"
            size="sm"
            className="gap-2 border-destructive/40 text-destructive transition-all duration-200 hover:bg-destructive/10"
            onClick={() => setRestoreOpen(true)}
          >
            <RotateCcw className="h-4 w-4" />
            {ar ? "استعادة نسخة احتياطية" : "Restore backup"}
          </Button>
          <Button size="sm" className="gap-2" disabled={run.isPending} onClick={() => run.mutate()}>
            <CloudUpload className="h-4 w-4" />
            {run.isPending
              ? ar
                ? "جارٍ العمل..."
                : "Running..."
              : ar
                ? "تشغيل نسخة احتياطية الآن"
                : "Run backup now"}
          </Button>
        </div>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="flex flex-wrap items-center gap-3 rounded-md border border-border p-3">
          <span className="text-sm text-muted-foreground">{ar ? "آخر نسخة:" : "Last backup:"}</span>
          <span className="text-sm font-medium">
            {last ? formatDateTime(last.created_at, lang) : ar ? "لا يوجد" : "None yet"}
          </span>
          {last && (
            <Badge variant={last.status === "success" ? "default" : "destructive"}>
              {last.status === "success" ? (ar ? "ناجحة" : "Success") : ar ? "فاشلة" : "Failed"}
            </Badge>
          )}
          {last?.file_name && <span className="font-mono text-xs">{last.file_name}</span>}
          {last?.file_size_bytes ? (
            <span className="text-xs text-muted-foreground">{sizeLabel(last.file_size_bytes)}</span>
          ) : null}
          {last?.drive_file_id && (
            <Badge variant="outline">{ar ? "على جوجل درايف" : "On Google Drive"}</Badge>
          )}
          {last?.drive_link && (
            <a
              href={last.drive_link}
             
              rel="noreferrer"
              className="inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline"
            >
              <ExternalLink className="h-3 w-3" />
              {ar ? "فتح الملف" : "Open file"}
            </a>
          )}
          {last?.drive_folder_id && (
            <a
              href={`https://drive.google.com/drive/folders/${last.drive_folder_id}`}
             
              rel="noreferrer"
              className="inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline"
            >
              <ExternalLink className="h-3 w-3" />
              {ar ? "مجلد 20s" : "20s folder"}
            </a>
          )}
        </div>

        {(history.data?.length ?? 0) > 0 && (
          <div className="space-y-2">
            {history.data!.map((row) => (
              <div
                key={row.id}
                className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border/60 bg-muted/30 px-3 py-2 text-xs transition-colors hover:bg-muted/60"
              >
                {row.drive_link ? (
                  <a
                    href={row.drive_link}
                   
                    rel="noreferrer"
                    className="font-mono text-primary hover:underline"
                  >
                    {row.file_name ?? "—"}
                  </a>
                ) : (
                  <span className="font-mono">{row.file_name ?? "—"}</span>
                )}
                <span className="text-muted-foreground">
                  {formatDateTime(row.created_at, lang)}
                </span>
                <span className="text-muted-foreground">{sizeLabel(row.file_size_bytes)}</span>
                <Badge
                  variant={row.status === "success" ? "secondary" : "destructive"}
                  className="text-[10px]"
                >
                  {row.status}
                </Badge>
                <Button
                  variant="ghost"
                  size="icon"
                  aria-label={ar ? "حذف النسخة" : "Delete backup"}
                  className="h-7 w-7 text-destructive transition-all duration-200 hover:bg-destructive/10"
                  onClick={() => setPendingDelete(row)}
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
                {row.error_message && (
                  <span className="w-full text-muted-foreground">{row.error_message}</span>
                )}
              </div>
            ))}
          </div>
        )}
      </CardContent>

      <Dialog
        open={Boolean(pendingDelete)}
        onOpenChange={(next) => {
          if (!next) setPendingDelete(null);
        }}
      >
        <DialogContent className="transition-all duration-200">
          <DialogHeader>
            <DialogTitle className="text-destructive">
              {ar
                ? "هل أنت متأكد من حذف هذه النسخة الاحتياطية نهائياً؟"
                : "Delete this backup permanently?"}
            </DialogTitle>
          </DialogHeader>
          <p className="font-mono text-xs text-muted-foreground">
            {pendingDelete?.file_name ?? "—"}
          </p>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPendingDelete(null)}>
              {ar ? "إلغاء" : "Cancel"}
            </Button>
            <Button
              variant="destructive"
              className="gap-2 transition-all duration-200"
              disabled={remove.isPending}
              onClick={() => pendingDelete && remove.mutate(pendingDelete.id)}
            >
              <Trash2 className="h-4 w-4" />
              {remove.isPending ? (ar ? "جارٍ الحذف..." : "Deleting...") : ar ? "حذف" : "Delete"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={restoreOpen}
        onOpenChange={(next) => {
          setRestoreOpen(next);
          if (!next) {
            setRestoreConfirm("");
            setRestorePayload(null);
            setRestoreName("");
          }
        }}
      >
        <DialogContent className="max-h-[90vh] overflow-y-auto transition-all duration-200">
          <DialogHeader>
            <DialogTitle className="text-destructive">
              {ar ? "استعادة نسخة احتياطية" : "Restore a backup"}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
              {ar
                ? "الاستعادة ستقوم باستبدال البيانات الحالية بالبيانات الموجودة في الملف."
                : "Restoring replaces current data with the data inside the file."}
            </p>

            <div className="grid gap-2">
              <Label htmlFor="restore-file">
                {ar ? "ملف نسخة احتياطية (JSON)" : "Backup file (JSON)"}
              </Label>
              <Input
                id="restore-file"
                type="file"
                accept="application/json,.json"
                onChange={(event) => {
                  const file = event.target.files?.[0];
                  if (file) void readLocalFile(file);
                }}
              />
            </div>

            {(history.data?.filter((row) => row.drive_file_id).length ?? 0) > 0 && (
              <div className="space-y-2">
                <span className="text-sm text-muted-foreground">
                  {ar ? "أو اختار نسخة محفوظة:" : "Or pick a stored snapshot:"}
                </span>
                <div className="space-y-1">
                  {history
                    .data!.filter((row) => row.drive_file_id)
                    .map((row) => (
                      <Button
                        key={row.id}
                        variant="outline"
                        size="sm"
                        className="w-full justify-between gap-2 font-mono text-xs transition-all duration-200"
                        disabled={pullFromDrive.isPending}
                        onClick={() => pullFromDrive.mutate(row)}
                      >
                        <span className="truncate">{row.file_name ?? "—"}</span>
                        <span className="text-muted-foreground">
                          {formatDateTime(row.created_at, lang)}
                        </span>
                      </Button>
                    ))}
                </div>
              </div>
            )}

            {restorePayload && (
              <p className="rounded-md border border-border bg-muted/40 p-2 text-xs">
                {ar ? "النسخة المختارة: " : "Selected snapshot: "}
                <span className="font-mono">{restoreName || "—"}</span>
              </p>
            )}

            <div className="grid gap-2">
              <Label htmlFor="restore-confirm">
                {ar ? `اكتب ${RESTORE_TEXT} للتأكيد` : `Type ${RESTORE_TEXT} to confirm`}
              </Label>
              <Input
                id="restore-confirm"
                value={restoreConfirm}
                autoComplete="off"
                placeholder={RESTORE_TEXT}
                onChange={(event) => setRestoreConfirm(event.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setRestoreOpen(false)}>
              {ar ? "إلغاء" : "Cancel"}
            </Button>
            <Button
              variant="destructive"
              className="gap-2 transition-all duration-200"
              disabled={restoreConfirm !== RESTORE_TEXT || !restorePayload || restore.isPending}
              onClick={() => restore.mutate()}
            >
              {restore.isPending ? (
                <>
                  <Loader2 className="h-4 w-4 animate-spin" />
                  {ar ? "جارٍ الاستعادة..." : "Restoring..."}
                </>
              ) : (
                <>
                  <RotateCcw className="h-4 w-4" />
                  {ar ? "استعادة الآن" : "Restore now"}
                </>
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
