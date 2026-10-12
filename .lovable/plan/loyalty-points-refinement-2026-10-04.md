# Loyalty & Points refinement

## Goal
Make customer management faster and clearer: one edit flow, a polished settings experience with a practical guide, and scalable pagination for customers, vouchers, and suppliers.

## What will change

### 1. Unified customer editing
- Replace the separate “Edit” and “Adjust points” actions with one customer edit dialog.
- Include name, phone, points change, and adjustment reason in one form.
- Keep points changes ledger-based through the existing points adjustment operation so order history and loyalty calculations remain intact.
- Save profile changes and points changes together from the user’s perspective, with validation, loading state, error feedback, and immediate list/history refresh.
- If profile fields are unchanged or the points change is zero, skip that operation safely.

### 2. Loyalty settings redesign
- Rebuild the settings tab as a clean RTL-first workspace with a clear enabled/disabled status, two focused setting panels, current-value summaries, and an explicit save action instead of saving unexpectedly on field blur.
- Use the existing teal/orange design tokens, subtle borders, shadows, icons, and responsive layout.
- Preserve the existing backend settings shape and loyalty formulas.

### 3. Practical loyalty guide
- Add a “دليل احتساب النقاط والقسائم” section driven by the live settings values.
- Show a concrete example for earning points, converting points to discount value, issuing a voucher, and redeeming it.
- Keep Arabic and English copy aligned and clearly state that issuing a voucher deducts the configured points cost, while redemption follows the existing voucher workflow.

### 4. Pagination and performance
- Add server-side pagination to customers and vouchers, with exact counts and page reset when search/filter input changes.
- Preserve simple sequential customer numbering across pages using the global row position, not a page-local index.
- Keep supplier summary calculations correct while paginating the displayed supplier rows through the shared table control.
- Add pagination to supplier invoice details to prevent large dialogs from becoming slow.

## Validation
- Validate name, phone, points delta, and reason before submission; retain server-side permission and duplicate-phone checks.
- Verify Arabic RTL and English layouts, the unified edit save flow, live guide calculations, page navigation, and page-reset behavior.
- Check the latest build diagnostics and exercise the central loyalty flow in the signed-in preview without changing production financial data.

## Technical notes
- Keep TanStack Query cache invalidation as the single UI synchronization path.
- Reuse the shared pagination control and existing UI components.
- No loyalty formula, order history, voucher accounting, or permissions behavior will be changed.
