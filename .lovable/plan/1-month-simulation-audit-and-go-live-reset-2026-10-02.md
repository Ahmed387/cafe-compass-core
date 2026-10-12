# 1-Month Simulation, Audit and Go-Live Reset

The database holds real data, and preview and live share it. So the simulation must never leave a row behind or touch real figures.

## 1. Simulation that rolls itself back
- One Super Admin-only database routine runs the whole month inside a protected block. At the end it deliberately cancels everything, so the database returns exactly to how it was before.
- During the run it acts as real users (Super Admin, 2 cashiers, a manager-partner) by setting the signed-in identity inside the database. That way every permission and security rule is exercised for real.
- 30 days covered:
  - Two shifts per day with different cashiers, plus orders paid in cash, by bank transfer and through QR.
  - Recipe stock use with the 1.05 waste factor, and one emergency stock override.
  - Attendance, advances, fixed salaries, and the percentage-based manager salary from net profit.
  - Running payroll and the "صرف الراتب" payout.
  - Locking a period, distributing profit to partners, reopening it, then locking it again (the reversal path).
  - Deactivating and archiving an employee who has history.
- After each step it records checks: expected vs. actual totals, no unexplained negative balances, rounding to 2 decimals, salary deducted exactly once, and partner shares summing to 100%.
- It returns only the results (pass/fail plus numbers). No data is kept.

## 2. Static audit
- Type check, the database linter and a security scan. RLS is reviewed for cashier isolation, salary visibility and partner visibility.
- Code review of the known risk spots (POS shift reads after the RLS change, the closing summary after a shift closes, the 5000-order limit).

## 3. Arabic report
- Delivered in chat. It lists what passed, what failed with numbers, edge cases, and recommended fixes. Bugs it finds are fixed in the same sprint where it is safe to do so.

## 4. Go-live reset button (Settings, Super Admin only)
- It wipes operations data: shifts, orders, payments, stock movements, expenses, payroll lines, attendance, advances, penalties/bonuses, periods, distributions, partner ledger entries and audit logs.
- It keeps settings, branches, the menu, recipes, inventory items, roles, user accounts and partners. Stock quantities can optionally be reset to zero.
- Two-step confirmation: you type "RESET" and give a reason. A single summary entry is written after the wipe.

## Technical details
- `run_month_simulation()`: SECURITY DEFINER plpgsql. The inner `BEGIN … EXCEPTION` subtransaction does all the work through existing RPCs, using `set_config('request.jwt.claims', …, true)` to impersonate. Results are collected into a jsonb variable, then `RAISE` triggers the rollback, and the outer block returns the jsonb. Simulated staff are created with throwaway profile rows inside the same subtransaction.
- `go_live_reset(_confirm text, _reset_stock bool)`: Super Admin check plus ordered deletes that respect foreign keys. It bypasses `forbid_hard_delete` through a session flag that only this function sets.
- UI: a "Run system simulation" card (shows the report) and a "Go-live reset" card in `/settings`.
