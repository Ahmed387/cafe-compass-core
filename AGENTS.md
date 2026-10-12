<!-- LOVABLE:BEGIN -->

> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.

<!-- LOVABLE:END -->
- Navigation is 5 hubs defined in `src/modules/shell/hubs.ts` (sidebar + sub-tab bar read it); add new pages as hub tabs there — one source of truth for nav.
- Shared page components live in `src/modules/<operations|supply|finance|catalog|governance>/`; route files stay in `src/routes/` because the router only discovers routes there.
- Public menu is `/menu`; staff product management is `/menu-studio`; `/soft-menu` and `/treasury` are redirects — keep old URLs working.
- Stock locations: `branch_stock.quantity` stays the branch TOTAL; `bar_quantity` is the bar share and main = total − bar. Why: every existing stock function keeps working unchanged.
- Partner liquidation is append-only and atomic: settle the final balance, deactivate the partner, and proportionally normalize remaining active shares to 100%. Why: financial history and equity integrity must survive lifecycle changes.
- Partner equity % is derived by trigger from active capital contributions (capital / total active capital); paused partners' shares stay retained. Why: ownership must always match money actually invested.
- Closed periods are locked in the database; Super Admin correction uses audited reopen/re-lock, while period deletion reverses active distributions append-only and retires referenced history atomically. Why: partner balances must roll back without destroying financial evidence.
- Open-ended accounting periods store `is_open_ended=true` with sentinel `end_date='9999-12-31'`; closing replaces it with the real end date. Why: every date-range RPC keeps working without null handling.
- Item cost = latest priced purchase-type stock movement (trigger on stock_movements); sales freeze cost on the movement/line. Why: forward pricing uses newest price while history stays intact.
- Shift and period COGS use each sale line's frozen unit cost plus the 5% operating-yield factor; never reprice historical sales from current recipes. Why: shift KPIs, P&L, and profit distribution must reconcile.
- Sales VAT is disabled and hidden; preserve historic tax columns only for audit compatibility and never include VAT in new order totals or financial UI. Why: the business does not apply VAT.
- Attendance payroll deductions use day fractions: absent = 1 day, half-day = 0.5 day, and permission hours ÷ 8. Why: payroll preview and issued payroll must match partial attendance.
- Period date ranges resolve only through `src/core/finance/periods.ts` (`isOpenEndedPeriod`, `periodEndDay`, `periodToIso`, `periodEndLabel`); never format or range-query `accounting_periods.end_date` directly. Why: the `9999-12-31` sentinel yields out-of-range timestamps for the backend and prints a fake end date in the UI.
