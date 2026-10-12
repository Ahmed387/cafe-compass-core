import { createServerFn } from "@tanstack/react-start";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

/**
 * Takes the mandatory pre-reset snapshot (uploaded to Google Drive) before any
 * operational data is deleted. Super admins only. The wipe itself runs in the
 * atomic `execute_operational_reset` database function.
 */
export const preResetBackup = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((input: { confirm: string }) => input)
  .handler(async ({ data, context }) => {
    const { data: isSuperAdmin, error } = await context.supabase.rpc("is_super_admin");
    if (error) throw new Error(error.message);
    if (!isSuperAdmin) throw new Error("not authorized");
    if (data.confirm !== "RESET-20S") throw new Error("confirmation text does not match");

    const { data: profile } = await context.supabase
      .from("user_profiles")
      .select("company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!profile?.company_id) throw new Error("not authorized");

    const { runBackupForCompany } = await import("@/lib/backup.server");
    const backup = await runBackupForCompany(profile.company_id, "20s_backup_pre_reset");
    if (backup.status !== "success") {
      throw new Error(`Pre-reset backup failed: ${backup.error_message ?? "unknown error"}`);
    }

    return { backup };
  });
