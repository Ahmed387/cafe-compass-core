# Sprint V4 — Page-by-Page KPIs, Smart Search & UI Polish

No historical records are deleted or changed. Items 7 (period override without a time limit, plus re-lock and recalculation) and 8 (Active / Archived tabs) are already built. This sprint only checks them in the browser.

## 1. KPI cards on every page (they update with search and filters)
- **Cashier (/pos)**: Shift sales, Orders count, Expected drawer cash, Short / over. These come from the same shared finance engine for the open shift.
- **Orders & Shifts (/orders, shifts tab)**: Period sales, Orders, Pending delivery, Refunded, Cancelled. They follow the date, status and search filters.
- **Inventory (/inventory) and Bar (/warehouse)**: Total items, Items at reorder level, Total stock value. They respect the active search.
- **Finance (/finance hub + period details)**: the 6 core cards. They are added at the top of the Finance hub for the current open period.
- **Partners**: Active capital, Active partners, Distributable net profit.
- **HR**: Active staff, Pending penalties, Total payroll.
- One shared card design is used everywhere: soft gradient, clear numbers, an optional colour for good or bad values.

## 2. Universal smart search and filters
- The shared search bar is extended and used on Inventory, Bar stock, Orders and Invoices, Shifts, the Refunds log, Returns, Partners and HR.
- Orders get filters for Shift #, Customer, Order type (dine-in / takeaway / delivery), Cashier, Item and Refunded. The KPI cards follow these filters.
- The Refunds log and Returns get the same search plus Shift # and Cashier filters.
- Inventory and Bar get a "low stock only" filter.

## 3. Cashier shift-opening redesign
- A single clean, centred card. It shows the opening cash (filled in automatically from the leftover change), a crew picker, and one big "Open shift" button.
- No nested boxes and no clipped borders. It works well on a tablet.

## 4. Shortage breakdown in shift details
- Cards in shift details show how each cash or stock shortage was settled: Venue absorbed, Staff penalty (with names), or Crew split (amount per person).
- These cards read from the existing penalty and stocktake records.

## 5. Clean-up
- **Roles**: the action matrix stays. The technical permission codes are hidden and the descriptions become clear.
- **Settings / Guide**: placeholder text and out-of-date guide sections are removed (Kitchen screen, old roles editor, old period reopen wording). Sections for Shift opening and closing, Stocktake and Partners lifecycle are updated.
- **QR**: the two duplicate cards become one polished QR generator with Print and Copy buttons.
- **Routes**: /cashier redirects to /pos and /bar redirects to /warehouse, so the names in the spec work.

## 6. Visual polish
- Consistent page spacing, glass-style KPI strips, softer shadows and harmonious teal/orange gradients, using the existing design tokens only.
- Every changed screen is checked for mobile responsiveness.

## 7–8. Verify only
- Browser walkthrough of: Override lock, then edit, then Save & Re-lock (recalculated shares, paused partners excluded, audit entries). Also the Active / Archived tabs on Partners and HR.

## Technical details
- New `src/components/shared/KpiCard.tsx` (`KpiCard`, `KpiGrid`) for presentation only. The data stays in each page or in small hooks.
- `SmartFilterBar` is extended (optional chips and toggle filters) without breaking Partners and HR.
- Orders KPIs: the existing `orders_period_summary` is extended with optional filter arguments for shift, type, cashier, item and refunded, so the totals stay server-side. The matching list query uses the same filters.
- Partners distributable profit uses the existing `period_financial_kpis` / `period_distribution` for the open period. HR pending penalties come from `staff_penalties` with status pending.
- Shortage breakdown: read `staff_penalties` linked to the shift and `stocktakes.settlement`.
- New redirect routes `cashier.tsx` and `bar.tsx`.
- Finish with: build 0 errors, linter review, and a Playwright check of each page.
