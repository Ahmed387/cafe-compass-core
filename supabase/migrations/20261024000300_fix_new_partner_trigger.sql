-- =====================================================================
-- Adding a partner failed: 'relation "old_rows" does not exist'.
-- trg_partner_share_snapshot serves both the INSERT trigger (new_rows only)
-- and the UPDATE trigger (old_rows + new_rows); plpgsql planned the whole
-- "TG_OP = 'UPDATE' AND NOT EXISTS (... old_rows ...)" expression on INSERT
-- too. The old_rows query now sits in its own IF, reached only on UPDATE.
-- No data is changed.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.trg_partner_share_snapshot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _c uuid; _today date; _now jsonb; _was jsonb;
BEGIN
  IF current_setting('app.share_apply', true) = 'on' THEN RETURN NULL; END IF;
  FOR _c IN SELECT DISTINCT company_id FROM new_rows LOOP
    IF TG_OP = 'UPDATE' THEN
      -- Only a real change of share or status counts (not a rename or a pause).
      IF NOT EXISTS (
        SELECT 1 FROM new_rows n JOIN old_rows o ON o.id = n.id
         WHERE n.company_id = _c AND (n.profit_share_percentage IS DISTINCT FROM o.profit_share_percentage
                                      OR n.status IS DISTINCT FROM o.status)) THEN
        CONTINUE;
      END IF;
    ELSIF NOT EXISTS (
      SELECT 1 FROM new_rows n WHERE n.company_id = _c AND COALESCE(n.profit_share_percentage, 0) > 0) THEN
      CONTINUE;
    END IF;
    _today := public.business_today(_c);
    SELECT COALESCE(jsonb_object_agg(p.id, round(p.profit_share_percentage, 4)), '{}'::jsonb) INTO _now
      FROM public.partners p
     WHERE p.company_id = _c AND p.status = 'active' AND COALESCE(p.profit_share_percentage, 0) > 0;
    SELECT COALESCE(jsonb_object_agg(sh.partner_id, round(sh.pct, 4)), '{}'::jsonb) INTO _was
      FROM public._partner_shares_at(_c, _today) sh
      JOIN public.partners p ON p.id = sh.partner_id AND p.status = 'active';
    IF _now <> _was AND _now <> '{}'::jsonb THEN
      INSERT INTO public.partner_share_snapshots (company_id, effective_from, shares, source, created_by)
      VALUES (_c, _today, _now, 'manual', public.current_profile_id());
    END IF;
  END LOOP;
  RETURN NULL;
END $function$;
