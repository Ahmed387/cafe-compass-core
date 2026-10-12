# Flexible periods, latest-price costing, financial cohesion

## What you will get
1. **Clean period reset from 18-09-2026**
   - The 4 current periods (Sep closed, Oct open, Oct-4 adjustment closed, Nov closed) are removed through the existing safe delete engine (no profit distributions exist yet, so nothing to reverse).
   - One new open-ended period starts 18-09-2026 and covers everything since the soft opening.
   - Inventory, purchases, shifts, orders, salaries and partners are untouched.
2. **Two ways to create a period** (Periods page, "New period" form gets a toggle)
   - **Open-ended:** start date only. Stays active until a Super Admin closes it; closing asks for the end date (defaults to today).
   - **Bounded:** start and end date, as today.
   - Rules: no overlapping periods; only one open-ended period at a time; a new period cannot start inside an open-ended one until it is closed.
3. **Latest purchase price costing**
   - Every received purchase sets the item cost to that purchase's unit price (already the case for receipts — will be made the single rule, including purchase edits/returns and manual stock additions with a price).
   - Recipe costs, order line cost and COGS always read the item's current cost at sale time, then are frozen on the sale line, so past/closed records never change while new sales use 20 instead of 15 immediately.
   - The 5% waste margin stays applied on recipe consumption.
4. **Financial cohesion**
   - Dashboard, P&L and period closing all compute from the same source: sales, frozen line COGS (incl. 5% waste), expenses, salaries, shortages — for whichever period covers the date, including open-ended (end = today while open).
   - Profit distribution uses the same numbers on close.

## Technical section
- Migration: `accounting_periods.end_date` nullable; validation trigger (no overlap treating NULL end as infinity, single open-ended row per company, closing requires end_date). Update `period_for_date` / `assert_period_open` / `ensure_open_periods` (stop auto-creating monthly periods when an open-ended one covers the date) and all summary RPCs to use `coalesce(end_date, current_date)`.
- Shifts/orders/stock movements stay bound by transaction date (no stored `period_id`), so they automatically map to the covering period — no data rewrites.
- `close_accounting_period` gains optional `_end_date` for open-ended periods.
- Costing: one helper `set_latest_item_cost(item, unit_cost)` called from purchase receive/edit and priced stock-in; `consume_recipe_on_sale` and modifier consumption read `cost_per_unit` live and store `unit_cost` on `order_items`; COGS report sums stored line cost.
- Data reset via the existing `delete_accounting_period` path (audited), then insert the 18-09-2026 open-ended period.
- UI: `periods.tsx` create dialog mode toggle, "Open-ended" badge, end shown as "Ongoing"; close dialog asks end date; PeriodImpactPanel copy updated.

## Needs your OK
- Deleting the 4 existing periods (audited, reversible history kept).
