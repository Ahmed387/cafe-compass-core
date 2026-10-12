# 20s Mega Suite — Remaining Work

## Already built (no rework, only regression checks)
- QR menu hero, AR/EN switch without reload, no "Soft Opening" text, `20S-` invoices, can and kraft cup images
- Catalog prices (Cold Brew 110, Cold Foam 20), Frappuccino = Frappe + 10, V60/Chemex bean options
- POS order notes, % or EGP discount, can +30 button, auto-attached can option for cold categories
- "Partially Refunded" badge showing original, refunded and net amounts
- Batch settlement of card and e-wallet payments, venue expenses, net profit, freezing shares, partner on-account deduction

## New work, in 3 phases

### Phase A — HR employee editor (`/hr`)
- Automatically list all staff and cashiers, including anyone with a profile but no salary set yet
- Clicking a row opens a side panel (Super Admin edits, everyone else view-only): name, job title (Cashier/Barista/Floor Staff/Manager), base salary, hire date, shifts and hours this month, add bonus, add penalty (can link to a refund), live net pay
- One "Save employee data" button that saves everything in a single step and records it in the activity log

### Phase B — Partner capital and profile (`/finance` → Partners)
- Each partner gets a paid capital amount. The total startup cost is the sum, and each partner's share % = their capital / total
- Manual share override switch (the shares must total 100%), with Super Admin editing names and capital
- Per-partner monthly freeze: a frozen partner's share stays in the treasury while the other partners are paid
- Partner profile panel: capital and share card, monthly profit, invoices list (paid now = green, on account = amber), net due = share − unpaid on-account invoices
- "Pay out profit" button: records the payment from the treasury, marks that month's dividend as paid, settles the included invoices. Partners can view only their own profile

### Phase C — Full end-to-end test and cleanup
- Steps 1–7 of Section 6: 300k/200k capital → 60/40, HR edit, partner override, Visa order with can + note + discount, partial refund, paid-now vs on-account, payout plus freeze
- Undo all test data automatically and confirm 0 build errors

## Technical details
- New columns: `partners.capital_contribution`, `partners.equity_override bool`; `user_profiles.job_title`; new table `partner_period_freezes(period_id, partner_id)` and `partner_dividend_payouts(period_id, partner_id, amount, cash_txn_id)`, both with GRANTs and RLS limited to Super Admin and the partner themselves
- RPCs (SECURITY DEFINER, Super Admin check, atomic, audited): `update_employee_profile`, `update_partner_profile`, `recalc_partner_equity`, `toggle_partner_freeze`, `payout_partner_dividend`
- `distribute_period_profit` skips frozen partners (their share is kept as retained earnings)
- UI: new `EmployeeDrawer.tsx` and `PartnerDrawer.tsx` using the existing Sheet component, RTL, with i18n keys in AR and EN
