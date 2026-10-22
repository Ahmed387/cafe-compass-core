-- =====================================================================
-- Daily backups after moving off Lovable (2026-10-22): the Google Drive upload
-- went through Lovable's connector gateway, which the Cloudflare site cannot
-- reach. Snapshots now go to a private Storage bucket, written by the
-- `daily-backup` Edge Function, which pg_cron calls every night at 01:00 UTC
-- (03:00/04:00 Cairo). The unauthenticated nightly call is a no-op when a
-- successful backup already exists from the last 20 hours.
-- No existing data is changed.
-- =====================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('backups', 'backups', false)
ON CONFLICT (id) DO NOTHING;

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'daily-backup';
SELECT cron.schedule('daily-backup', '0 1 * * *', $$
  SELECT net.http_post(
    url := 'https://xkouveyxcwknadniatdd.supabase.co/functions/v1/daily-backup',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 60000);
$$);
