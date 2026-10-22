/**
 * Backup engine: the `daily-backup` Supabase Edge Function builds a gzipped JSON
 * snapshot of the whole company archive, stores it in the private `backups`
 * Storage bucket and records it in backup_history (drive_file_id = "storage:<path>").
 * pg_cron runs it nightly; this module runs it on demand. It never mutates
 * business data.
 */

export const STORAGE_PREFIX = "storage:";
export const BACKUP_BUCKET = "backups";

export type BackupResult = {
  status: "success" | "failed";
  file_name: string;
  file_size_bytes: number;
  drive_file_id: string | null;
  drive_link: string | null;
  drive_folder_id: string | null;
  uploaded: boolean;
  note: string | null;
  error_message: string | null;
};

type FunctionRun = { companyId: string; file?: string; bytes?: number; error?: string };

function failed(message: string): BackupResult {
  return {
    status: "failed",
    file_name: "",
    file_size_bytes: 0,
    drive_file_id: null,
    drive_link: null,
    drive_folder_id: null,
    uploaded: false,
    note: null,
    error_message: message.slice(0, 500),
  };
}

/** Runs a backup now (forced, ignores the nightly 20-hour gap). Never throws. */
export async function runBackupForCompany(
  companyId: string,
  filePrefix = "20s_backup",
): Promise<BackupResult> {
  const url = process.env["SUPABASE_URL"];
  const key = process.env["SUPABASE_SERVICE_ROLE_KEY"];
  if (!url || !key) return failed("Backup is not configured (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY).");

  try {
    const response = await fetch(`${url}/functions/v1/daily-backup`, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ prefix: filePrefix }),
    });
    const text = await response.text();
    if (!response.ok) return failed(`Backup function failed [${response.status}]: ${text}`);
    const body = JSON.parse(text) as { results?: FunctionRun[] };
    const run = body.results?.find((r) => r.companyId === companyId);
    if (!run) return failed("Backup function returned no result for this company.");
    if (run.error || !run.file) return failed(run.error ?? "Backup failed.");
    return {
      status: "success",
      file_name: run.file,
      file_size_bytes: run.bytes ?? 0,
      drive_file_id: `${STORAGE_PREFIX}${companyId}/${run.file}`,
      drive_link: null,
      drive_folder_id: null,
      uploaded: true,
      note: null,
      error_message: null,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("Backup failed:", message);
    return failed(message);
  }
}
