import { createServerFn } from "@tanstack/react-start";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import type { Json } from "@/integrations/supabase/types";

/** Manual backup trigger — super admins only. */
export const runBackupNow = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    const { data: isSuperAdmin, error } = await context.supabase.rpc("is_super_admin");
    if (error) throw new Error(error.message);
    if (!isSuperAdmin) throw new Error("not authorized");

    const { data: profile } = await context.supabase
      .from("user_profiles")
      .select("company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!profile?.company_id) throw new Error("not authorized");

    const { runBackupForCompany } = await import("@/lib/backup.server");
    return runBackupForCompany(profile.company_id);
  });

/** Downloadable snapshot for super admins (raw JSON, generated on demand). */
export const downloadSnapshot = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    const { data, error } = await context.supabase.rpc("company_financial_snapshot", {});
    if (error) throw new Error(error.message);
    return data;
  });

/**
 * Permanently deletes one backup: its stored file (Storage, or Google Drive for
 * older backups) plus its `backup_history` row. Super admins only.
 */
export const deleteBackup = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((input: { id: string }) => input)
  .handler(async ({ data, context }) => {
    const { data: isSuperAdmin, error } = await context.supabase.rpc("is_super_admin");
    if (error) throw new Error(error.message);
    if (!isSuperAdmin) throw new Error("not authorized");

    const { data: row, error: rowError } = await context.supabase
      .from("backup_history")
      .select("id, drive_file_id")
      .eq("id", data.id)
      .maybeSingle();
    if (rowError) throw new Error(rowError.message);
    if (!row) throw new Error("backup not found");

    // File removal is best-effort: a missing or unreachable file must never
    // block clearing the history row.
    let driveDeleted = false;
    const { STORAGE_PREFIX, BACKUP_BUCKET } = await import("@/lib/backup.server");
    if (row.drive_file_id?.startsWith(STORAGE_PREFIX)) {
      const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
      const { error: removeError } = await supabaseAdmin.storage
        .from(BACKUP_BUCKET)
        .remove([row.drive_file_id.slice(STORAGE_PREFIX.length)]);
      driveDeleted = !removeError;
      if (removeError) console.warn("Storage delete failed, continuing:", removeError.message);
    } else if (row.drive_file_id) {
      const lovableKey = process.env["LOVABLE_API_KEY"];
      const connectionKey = process.env["GOOGLE_DRIVE_API_KEY"];
      if (lovableKey && connectionKey) {
        try {
          const response = await fetch(
            `https://connector-gateway.lovable.dev/google_drive/drive/v3/files/${row.drive_file_id}`,
            {
              method: "DELETE",
              headers: {
                Authorization: `Bearer ${lovableKey}`,
                "X-Connection-Api-Key": connectionKey,
              },
            },
          );
          driveDeleted = response.ok || response.status === 404;
          if (!driveDeleted) {
            console.warn(`Drive delete skipped [${response.status}] for ${row.drive_file_id}`);
          }
        } catch (error) {
          console.warn("Drive delete failed, continuing:", error);
        }
      }
    }

    const { error: deleteError } = await context.supabase.rpc("delete_backup_entry", {
      p_id: data.id,
    });
    if (deleteError) throw new Error(deleteError.message);

    return { id: data.id, driveDeleted };
  });

/**
 * Gives the browser a short-lived link to a stored snapshot so it can download
 * and unzip it itself (the worker never parses the multi-MB JSON). Older
 * Google Drive backups are still fetched through the Lovable gateway when its
 * keys are present.
 */
export const fetchBackupPayload = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((input: { id: string }) => input)
  .handler(async ({ data, context }) => {
    const { data: isSuperAdmin, error } = await context.supabase.rpc("is_super_admin");
    if (error) throw new Error(error.message);
    if (!isSuperAdmin) throw new Error("not authorized");

    const { data: row, error: rowError } = await context.supabase
      .from("backup_history")
      .select("id, drive_file_id, file_name")
      .eq("id", data.id)
      .maybeSingle();
    if (rowError) throw new Error(rowError.message);
    if (!row?.drive_file_id) throw new Error("this backup has no stored file");

    const { STORAGE_PREFIX, BACKUP_BUCKET } = await import("@/lib/backup.server");
    if (row.drive_file_id.startsWith(STORAGE_PREFIX)) {
      const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
      const { data: signed, error: signError } = await supabaseAdmin.storage
        .from(BACKUP_BUCKET)
        .createSignedUrl(row.drive_file_id.slice(STORAGE_PREFIX.length), 300);
      if (signError || !signed) throw new Error(signError?.message ?? "could not open the backup file");
      return { file_name: row.file_name, url: signed.signedUrl, payload: null };
    }

    const lovableKey = process.env["LOVABLE_API_KEY"];
    const connectionKey = process.env["GOOGLE_DRIVE_API_KEY"];
    if (!lovableKey || !connectionKey) throw new Error("Google Drive is not connected");

    const response = await fetch(
      `https://connector-gateway.lovable.dev/google_drive/drive/v3/files/${row.drive_file_id}?alt=media`,
      {
        headers: {
          Authorization: `Bearer ${lovableKey}`,
          "X-Connection-Api-Key": connectionKey,
        },
      },
    );
    if (!response.ok) {
      throw new Error(`Drive download failed [${response.status}]`);
    }
    const payload = (await response.json()) as Record<string, Json>;
    return { file_name: row.file_name, url: null, payload };
  });
