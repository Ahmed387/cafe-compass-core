// Daily backup: saves a gzipped JSON snapshot of every company into the private
// `backups` Storage bucket and records it in backup_history.
// Scheduled by pg_cron (no auth, at most one run per 20 hours) and run on demand
// by the app's "backup now" button (service-role bearer, always runs).
import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "backups";
const MIN_GAP_MS = 20 * 60 * 60 * 1000;

function fileName(prefix: string, date = new Date()) {
  const iso = date.toISOString();
  return `${prefix}_${iso.slice(0, 10)}_${iso.slice(11, 19).replace(/:/g, "")}.json.gz`;
}

async function gzip(text: string) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// A forced run needs a service-role key (legacy JWT or sb_secret_). Rather than
// compare strings with whichever form this runtime holds, ask Auth's admin API.
async function isServiceKey(token: string) {
  if (!token) return false;
  const probe = createClient(Deno.env.get("SUPABASE_URL")!, token, { auth: { persistSession: false } });
  const { error } = await probe.auth.admin.listUsers({ page: 1, perPage: 1 });
  return !error;
}

Deno.serve(async (req) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey, {
    auth: { persistSession: false },
  });
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const forced = bearer === serviceKey || (await isServiceKey(bearer));
  const body = forced ? ((await req.json().catch(() => ({}))) as { prefix?: string }) : {};
  const prefix = /^[A-Za-z0-9_-]{1,40}$/.test(body.prefix ?? "") ? body.prefix! : "20s_backup";

  const { data: companies, error } = await admin.from("companies").select("id");
  if (error) return Response.json({ ok: false, error: error.message }, { status: 500 });

  const results = [];
  for (const { id: companyId } of companies ?? []) {
    if (!forced) {
      const { data: recent } = await admin
        .from("backup_history")
        .select("id")
        .eq("company_id", companyId)
        .eq("status", "success")
        .gte("created_at", new Date(Date.now() - MIN_GAP_MS).toISOString())
        .limit(1);
      if (recent?.length) {
        results.push({ companyId, skipped: true });
        continue;
      }
    }

    const name = fileName(prefix);
    const path = `${companyId}/${name}`;
    try {
      const { data, error: snapError } = await admin.rpc("company_financial_snapshot", {
        _company_id: companyId,
      });
      if (snapError) throw new Error(snapError.message);
      const gz = await gzip(JSON.stringify(data));
      const { error: upError } = await admin.storage
        .from(BUCKET)
        .upload(path, gz, { contentType: "application/gzip", upsert: false });
      if (upError) throw new Error(upError.message);
      await admin.from("backup_history").insert({
        company_id: companyId,
        status: "success",
        file_name: name,
        file_size_bytes: gz.byteLength,
        drive_file_id: `storage:${path}`,
      });
      results.push({ companyId, file: name, bytes: gz.byteLength });
    } catch (e) {
      const message = (e instanceof Error ? e.message : String(e)).slice(0, 500);
      await admin.from("backup_history").insert({
        company_id: companyId,
        status: "failed",
        file_name: name,
        error_message: message,
      });
      results.push({ companyId, error: message });
    }
  }
  return Response.json({ ok: true, forced, results });
});
