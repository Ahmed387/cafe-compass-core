CREATE OR REPLACE FUNCTION public.delete_partner_safe(_partner_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_name text; v_blockers text[] := '{}'; v_count int;
begin
  if not public.is_super_admin() then raise exception 'Only the Super Admin can delete a partner.'; end if;
  select name into v_name from public.partners where id = _partner_id;
  if not found then raise exception 'Partner not found.'; end if;
  select count(*) into v_count from public.partner_capital_contributions where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('capital contributions (%s)', v_count); end if;
  select count(*) into v_count from public.partner_ledger_transactions where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('ledger transactions (%s)', v_count); end if;
  select count(*) into v_count from public.partner_dividend_payouts where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('dividend payouts (%s)', v_count); end if;
  select count(*) into v_count from public.profit_distribution_lines where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('profit distribution lines (%s)', v_count); end if;
  select count(*) into v_count from public.partner_tab_orders where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('partner tab orders (%s)', v_count); end if;
  select count(*) into v_count from public.partner_withdrawal_requests where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('withdrawal requests (%s)', v_count); end if;
  select count(*) into v_count from public.partner_liquidations where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('liquidation records (%s)', v_count); end if;
  select count(*) into v_count from public.period_partner_shares where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('period share snapshots (%s)', v_count); end if;
  select count(*) into v_count from public.partner_period_freezes where partner_id = _partner_id;
  if v_count > 0 then v_blockers := v_blockers || format('period freezes (%s)', v_count); end if;
  if array_length(v_blockers, 1) is not null then
    raise exception 'Cannot delete partner "%": linked financial records exist — %. Use liquidation instead.', v_name, array_to_string(v_blockers, ', ');
  end if;
  delete from public.partners where id = _partner_id;
  perform public.log_audit('delete_partner'::text, 'partners'::text, 'partner'::text, _partner_id,
    jsonb_build_object('partner_name', v_name), null::jsonb, 'Deleted mistakenly added partner'::text, null::uuid);
end;
$function$;
REVOKE ALL ON FUNCTION public.delete_partner_safe(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.delete_partner_safe(uuid) TO authenticated;