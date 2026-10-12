# Orders & Universal KPI Drill-Down

## Goal
Rebuild `/orders` into a clear financial hierarchy and make every summary/KPI card consistently interactive, explainable, and responsive without changing financial calculations.

## What will change

### 1. Orders tab hierarchy
- Place one full-width master revenue card immediately below the unified filters.
- Add a five-card payment grid below it: Cash, InstaPay, Wallets, Visa, and Partner Account, each with amount and transaction count.
- Move operational counts into a separate row: orders, pending delivery, refunded, and cancelled.
- Keep the order table and export action below the summary area.
- Preserve all existing filters; every card and its detail view will follow the active date, status, shift, order type, payment, and search filters.

### 2. Shifts tab hierarchy
- Reorder the current shift summary into distinct groups:
  1. Master revenue card.
  2. Payment-method breakdown grid.
  3. Profit and cost row.
  4. Expenses and drawer reconciliation rows.
  5. Shortage settlement cards and shift table.
- Keep all existing formulas and historical values unchanged.

### 3. Universal interactive KPI component
- Extend the shared KPI card contract with:
  - calculation formula and named data source;
  - a detail title and structured detail content;
  - keyboard-accessible click behavior and visible drill-down affordance;
  - a consistent detail dialog that scrolls correctly on phones.
- Add a reusable master metric variant and payment metric variant rather than duplicating card markup.
- Migrate summary/KPI cards across the authenticated application to this shared interaction pattern. Ordinary content cards remain non-interactive.

### 4. Exact drill-down data
- Orders metrics open filtered invoice lists with invoice number, time, status, payment, and net amount.
- Payment cards open only transactions for that tender, with invoice references and totals.
- Shift revenue/profit cards show contributing sales, refunds, COGS, waste, and expenses; drawer cards show shift-by-shift expected, counted, and variance values.
- Other application KPIs use their existing page records or queries to show the records behind the number. If a metric is a derived aggregate, its dialog shows every input term and the resulting equation—never invented detail rows.

### 5. Formula tooltips and visual system
- Every migrated KPI gets a subtle info icon with a hover/focus tooltip explaining “how this was calculated” and its source.
- Standardize cards on semantic design tokens, `rounded-xl`, explicit borders, soft shadows, restrained gradients, and stable responsive grids.
- Keep all text readable in Arabic and English, with no clipping or overlap.

## Technical details
- Keep `useFinancialEngine` and the existing finance helpers as the only money-calculation sources.
- Add typed metric-detail models and shared dialog/tooltip primitives under shared components.
- Reuse already-fetched records when possible; add narrowly scoped queries only where a drill-down needs records not present in the page payload.
- Do not change database schema, permissions, period locking, stock, or accounting history.

## Verification
- Check Orders and Shifts on desktop and mobile, including every new card, tooltip, and dialog.
- Spot-check migrated KPI cards on Cashier, Finance, Inventory/Bar, HR, Partners, Returns/Refunds, and Settings-related summaries.
- Confirm dialogs scroll, grids stack, keyboard activation works, totals reconcile with displayed rows, and the latest build reports zero TypeScript/build errors.
