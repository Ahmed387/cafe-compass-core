# Roadmap

## Sprint 3 — DONE (published, verified by user)
- Dual-warehouse engine, recipes (×1.05 yield), smart stocktake, purchases/payments/attachments — shipped.
- Venue-absorbed shrinkage fed into P&L (period_pnl + useFinancialEngine grossMargin).
- Leaked-password protection: user decided to keep OFF. No action.

## Backlog (non-blocking, user-approved)
- [x] UI pass: expose venue-absorbed shrinkage as a distinct line on shift summary cards (ShiftLedgerKpis) — net margin calc approved as-is; display-only change.
- [x] Recipes for the 120 synced soft-opening items → real COGS (currently 0).
- [x] Set bar_min_qty reorder levels per item (low-stock alerts currently inert until set).

## Sprint 4 — UI/UX, financial cards, permissions, lifecycle
- [x] Verify and align six financial KPI cards across shifts and finance reports
- [x] Replace role permissions editor with a critical-action matrix
- [x] Add staff inactivity enforcement while preserving history
- [x] Add partner liquidation and equity redistribution workflow
- [x] Modernize POS touch targets, alerts, spacing, and manager navigation typography
- [x] Validate RLS, TypeScript build, and central user flows

## Sprint V4 — page KPIs, smart search, polish
- [x] Shared KPI cards on POS, Orders, Inventory, Bar, Finance, Partners, HR
- [x] Smart search/filters on Inventory, Bar, Orders, Refunds, Returns
- [x] Shift opening redesign + shortage breakdown cards
- [x] Roles/Settings/Guide/QR clean-up, /cashier & /bar redirects

## Orders & universal KPI drill-down
- [x] Rebuild Orders and Shifts summaries into the approved financial hierarchy
- [x] Make shared KPI cards clickable with formula/source explanations and exact detail rows where available
- [x] Verify Orders and Shifts interactions on desktop and mobile with zero build errors

## Team management and accounting periods
- [x] Move active/archive filtering into the Team & Permissions header
- [x] Add full employee editing and attachment deletion
- [x] Preserve employee operational history when removing access
- [x] Add period create/edit/delete controls with atomic distribution rollback
- [x] Verify team and periods flows (build OK)

## Loyalty and large-list usability
- [x] Unify customer details and points adjustment in one validated editor
- [x] Redesign loyalty settings with explicit save and a live practical guide
- [x] Paginate customer, voucher, supplier, and supplier-invoice lists

## Inventory and profitability refinement
- [x] Compact the inventory and stock-movement tables
- [x] Add exact shift gross profit from frozen sale-time COGS plus 5% operating waste
- [x] Add a dedicated P&L page with owner-focused summary metrics
- [x] Review the five Project monitoring findings; user requested a status report only, with no fixes in this scope

## Attendance and P&L usability
- [x] Remove duplicated P&L KPI cards and switch the page to a clean light theme
- [x] Add half-day and hourly-permission attendance states to the calendar and batch updates
- [x] Apply proportional payroll deductions: half-day = 0.5 day; permission hours ÷ 8

## Open-ended period display
- [x] Stop the period details modal crashing on the `9999-12-31` sentinel end date
- [x] Show "مستمرة / Ongoing" instead of a fake end date in period details, dashboard, manager salary, dividends and action impact
- [x] Verify the open period's details dialog opens with full KPIs, payments and shift ledger in both languages
