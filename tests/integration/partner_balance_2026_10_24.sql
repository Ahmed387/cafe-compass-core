-- Partner balance without capital + liquidation + treasury drawers (2026-10-24).
-- Runs in a rolled-back block on "20s"; expected result line:
--   every partner balance 0.00 with capital shown apart (e.g. Husam 0.00 / cap 200000.00),
--   a 1,000 withdrawal is refused (available 0.00),
--   liquidating Ziad settles 150000.00 and leaves balance 0 + capital 0
--   (capital_contribution 150000 then partner_capital_return withdrawal 150000).
DO $r$ DECLARE _uid uuid; _res text := ''; _z uuid; _err text; _l uuid; _fb numeric;
BEGIN
  SELECT up.auth_user_id INTO _uid FROM user_profiles up JOIN user_roles ur ON ur.user_id = up.id JOIN roles r ON r.id = ur.role_id
   WHERE r.key='super_admin' AND up.is_active AND up.auth_user_id IS NOT NULL ORDER BY up.created_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role','authenticated')::text, true);
  SELECT string_agg(name || '=' || balance || '/cap ' || capital, '; ' ORDER BY name) INTO _res FROM partner_balances;
  SELECT id INTO _z FROM partners WHERE name = 'Ziad Mostafa';
  BEGIN PERFORM public.request_partner_withdrawal(1000, 'cash', NULL, _z); _res := _res || ' | withdraw ALLOWED';
  EXCEPTION WHEN OTHERS THEN _res := _res || ' | withdraw blocked: ' || SQLERRM; END;
  _l := public.liquidate_partner(_z, 'ledger', NULL, 'test');
  SELECT final_balance INTO _fb FROM partner_liquidations WHERE id = _l;
  _res := _res || ' | liquidation final=' || _fb || ' after=' || public.partner_balance(_z) || '+' || public._partner_ledger_capital(_z)
     || ' rows=' || (SELECT string_agg(reference_type||':'||transaction_type||':'||amount, ',') FROM partner_ledger_transactions WHERE partner_id=_z) || ' ledger_sum=' || (SELECT SUM(CASE WHEN transaction_type='withdrawal' THEN -abs(amount) ELSE amount END) FROM partner_ledger_transactions WHERE partner_id=_z AND status='active');
  _res := _res || ' | treasury ' || (public.treasury_overview() - 'accounts')::text;
  RAISE EXCEPTION 'RESULT %', _res;
END $r$;
