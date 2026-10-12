import { createFileRoute } from "@tanstack/react-router";

/**
 * Scheduled backup endpoint for external schedulers.
 * Protected by the BACKUP_SECRET_KEY bearer token — no session involved.
 */
export const Route = createFileRoute("/api/public/backups/run")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const secret = process.env["BACKUP_SECRET_KEY"];
        if (!secret) {
          console.warn("Backup endpoint: Credentials missing (BACKUP_SECRET_KEY)");
          return Response.json(
            { ok: false, error: "Backup endpoint not configured" },
            { status: 503 },
          );
        }

        const header = request.headers.get("authorization") ?? "";
        const provided = header.startsWith("Bearer ")
          ? header.slice(7)
          : (request.headers.get("x-backup-secret") ?? "");
        if (provided.length !== secret.length || provided !== secret) {
          return new Response("Unauthorized", { status: 401 });
        }

        const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
        const { data: companies, error } = await supabaseAdmin.from("companies").select("id");
        if (error) {
          console.error("Backup endpoint: could not list companies:", error.message);
          return Response.json(
            { ok: false, error: "Snapshot source unavailable" },
            { status: 500 },
          );
        }

        const { runBackupForCompany } = await import("@/lib/backup.server");
        const results = [];
        for (const company of companies ?? []) {
          results.push(await runBackupForCompany(company.id));
        }
        return Response.json({ ok: true, runs: results.length, results });
      },
    },
  },
});
