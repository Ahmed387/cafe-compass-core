# Sprint 4 implementation plan

## Outcome
Deliver a consistent financial summary, a fast role-permission matrix, safe staff/partner lifecycle controls, and a cleaner touch-first operating interface without deleting historical records.

## 1. Financial KPI cards
- Create one reusable six-card summary used by shift details and accounting-period reports:
  1. Gross Revenue
  2. COGS × 1.05
  3. Gross Margin
  4. OpEx + Venue Shrinkage
  5. Net Operating Profit
  6. Drawer Cash Variance
- Keep all arithmetic in the shared financial layer. For shifts: gross margin is net sales minus yielded COGS; OpEx combines linked shift expenses, waste, venue-absorbed refunds, and venue shrinkage; net operating profit subtracts that OpEx bundle.
- Extend period P&L output with the same fields and aggregate closed-shift drawer variance, then replace the current mixed nine-card calculations with the canonical six cards.
- Keep detailed refunds, payment methods, payroll, tax, and shift rows below the summary for audit depth.

## 2. Interactive permission matrix
- Replace the role-by-role permission list with a table whose columns are **Super Admin**, **Manager**, and **Cashier** and whose rows are the five critical actions.
- Map and enforce:
  - product costs/profits → `products.view_cost` and profit-report access
  - manual drawer control → existing `shifts.adjust_cash`
  - approve stocktakes → `inventory.adjust`
  - create purchases → `purchases.create`
  - emergency bar transfer → a dedicated new permission
- Toggles write through one protected database action, log every change, and refresh the current access state immediately.
- Preserve the permanent Root Super Admin protections; the matrix cannot demote or override the root account.
- Tighten cost/profit read paths and emergency-transfer checks so toggles affect backend authorization, not only visibility.

## 3. Staff lifecycle
- Keep `user_profiles.is_active` as the soft-delete source of truth and preserve every historical order, shift, attendance, and payroll link.
- Retain the existing active/inactive control and active-only staff/roster lists.
- Complete enforcement by rejecting inactive profiles during authenticated entry, signing out any stale session, and showing a clear inactive-account message.
- Keep database permission and roster checks as the final enforcement layer.

## 4. Partner liquidation
- Add an immutable liquidation record and one atomic Super-Admin-only action.
- The confirmation flow displays the calculated final balance and supports **treasury cash**, **bank transfer**, or **ledger-only settlement**.
- Cash settlement must pass treasury-balance checks; bank and ledger settlement remain auditable without requiring drawer cash.
- On confirmation, append settlement/ledger records, set the partner to `inactive`, retain all historical records, and redistribute the released equity proportionally across remaining active partners.
- Show the proposed post-liquidation percentages before confirmation and re-check transactionally that the active pool equals exactly 100%.
- Block duplicate liquidation and unresolved states that would make the final balance ambiguous, then record the complete before/after snapshot in audit history.

## 5. UI/UX modernization
- Increase POS primary controls, category tabs, product actions, quantity controls, and payment controls to at least 44px touch targets.
- Restyle ingredient/low-stock alerts as concise, high-contrast operational banners and improve product/cart spacing without changing workflows.
- Streamline the five-hub tab bar by hiding redundant entries, retaining legacy redirects, and applying one typography hierarchy across manager pages.
- Preserve RTL, bilingual labels, semantic colors, and current teal/orange identity.

## Validation
- Apply schema, permission, RLS, function, and audit changes through migrations with explicit grants.
- Verify Admin/Manager/Cashier matrix behavior, inactive login rejection, roster exclusion, all three liquidation settlement methods, proportional 100% equity redistribution, shift cards, and period cards.
- Run security/linter review, focused automated checks, desktop/mobile browser flows, and confirm zero TypeScript/build errors.

## Technical notes
- No table or historical row will be dropped, truncated, or overwritten.
- `Super Admin` is the requested Admin column; no separate Admin role will be created.
- Leaked-password protection and mandatory email confirmations remain off by prior decision.
