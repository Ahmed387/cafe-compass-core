# Ultimate Master Sprint — Gap-Closing Plan

Most of this spec already exists from Sprints 1–4. This sprint first audits each item against the live system, then builds only what is missing. No existing records are deleted or overwritten.

## Already in place (verify only)
- POS sale: deducts bar stock via recipes, COGS x1.05, updates expected drawer cash, feeds P&L.
- Purchases: stock update, pay from Treasury or Shift Drawer or Bank, supplier payables, private receipt attachments.
- Stocktake shortage: 3 settlement choices (venue / one staff / split across shift crew).
- 6 KPI cards on shift details and period details.
- Partner freeze toggle, partner liquidation with proportional 100% re-normalisation.
- Inactive staff blocked from login.

Each one gets an end-to-end check with real data. Anything that fails gets fixed.

## To build

### 1. Stocktake settlement correctness
- Confirm "charge to staff" and "split across shift" never reduce venue profit (only "venue absorbs" does). Fix the P&L filter if needed.

### 2. Capital-based equity
- Equity % always calculated as Partner Capital / Total Active Capital x 100, recalculated on every capital contribution and after liquidation.
- Rename/confirm the freeze toggle as "Pause Dividends": paused partners' share goes to retained earnings, not to other partners. Note: this changes the current behaviour, where the paused share is redistributed to the other partners.

### 3. Active vs Archived tabs
- `/partners` and `/hr`: tabs for "Active" and "Archived / Deactivated", with counts.
- Deactivated staff are hidden from shift crew pickers, scheduling and penalty pickers. Their history stays linked.

### 4. Smart search and filters
- Live search box plus filters on: Inventory (low stock, location), Bar stock, Staff (active/archived), Partners (active/archived), Invoices (accounting period, status, payment method).
- One shared search and filter bar used on every page.

### 5. Period close, distribution and lock
- Closing routine: distributable net profit, then skip paused partners, then split by capital equity, all in one step.
- Closed and distributed periods are locked. The database rejects any edit to them.
- Super Admin override: a warning dialog that requires typing to confirm, then an audit log entry. Normal corrections go into an Adjustment Period instead.

## Technical details
- New shared component `src/modules/shell/SmartFilterBar.tsx`. Used in inventory, warehouse, UsersPage/HR, partners, orders.
- Migration: an `equity_from_capital()` trigger on capital contributions and liquidations. `distribute_period_profit` updated so paused shares post to retained earnings. `close_and_distribute_period` RPC (atomic). `block_closed_period_entry` extended with a session-scoped Super Admin override flag set by `override_locked_period(_period_id, _reason)`, which writes to `audit_logs`. Adjustment period uses the existing `period_type = 'custom'` plus a flag column.
- Staff pickers filter on `user_profiles.is_active = true`. HR reads both lists by tab.
- All new functions are SECURITY DEFINER with internal role checks, granted to authenticated and service_role. All new tables get GRANT + RLS.
- Leaked-password protection and email confirmation stay OFF.
- Final step: build log 0 errors, linter review, browser walkthrough of every item above.
