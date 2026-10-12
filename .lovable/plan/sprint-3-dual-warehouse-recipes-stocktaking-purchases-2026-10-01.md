# Sprint 3 — Dual-Warehouse, Recipes, Stocktaking & Purchases

Nothing is deleted. All current stock, recipes (103), items (65) and purchases are kept. Today every branch has one stock pile; all of it will become the **Main Storage** balance, and Bar starts at 0 until the first transfer.

Delivered one phase at a time (like Sprint 2), each ending with a real test and a clean build.

## Phase A — Two storage locations + transfers
- Every branch gets two stores: **المخزن الرئيسي** and **مخزن البار والتشغيل**. Inventory page shows both balances side by side.
- Purchases received go into Main Storage.
- **Transfer request** (barista/manager): items + quantities, Main to Bar. Status: pending, then approved or rejected.
- Only a manager/admin can approve. Approval moves the stock in one step (fails when Main Storage does not have enough).
- Each item gets a **Bar reorder level**. When Bar drops below it, a red "اطلب من المخزن الرئيسي" alert shows, with a one-click transfer request.

## Phase B — Recipes and automatic consumption
- Recipe editor per menu item and size: ingredient, quantity, unit (g / kg, ml / L, piece), converted to the item's stock unit.
- Covers the 120 synced catalog items, which have no recipes right now and therefore show COGS 0.
- Selling on POS deducts ingredients **from the Bar only**.
- Recipe cost = ingredient cost × 1.05 shows on each item. The shared money engine uses it, so shift and finance cards show real COGS and gross margin.

## Phase C — Smart stocktake
- Choose the scope: Bar only, Main only, or both. Count screen lists expected quantities and takes the actual counts.
- Per item: expected = start + transfers in − POS consumption (+ purchases for Main); variance = counted − expected.
- Allowance: 5% of consumption, plus waste already charged to staff as HR penalties.
- Anything left over shows in **red** with the quantity and its cost in EGP. Approving the count sets the stock to the counted amount (logged as a stocktake movement).

## Phase D — Purchases ledger upgrade
- Payment status: **كاش / تحويل بنكي / آجل**. Credit purchases show as supplier payables, and you can settle them later.
- Cash purchases can be paid from the Treasury or the Safe, which records a cash transaction.
- Attach receipt photos or PDFs to each purchase (private file storage, visible only to staff with purchase access).

## Technical section
- New `stock_location` enum (`main`,`bar`), column `location` on `branch_stock` + `stock_movements` (default `main` backfills existing rows), unique (item, branch, location). `apply_stock_movement` gets a location param (old signature kept, defaults to main).
- `inventory_items.bar_min_qty`. New tables `stock_transfers` + `stock_transfer_items`; RPCs `request_stock_transfer`, `approve_stock_transfer`, `reject_stock_transfer` (atomic, audited).
- `consume_recipe_on_sale` / modifier trigger switch to `location='bar'`. `product_recipes.unit` + conversion helper. `useFinancialEngine` reads recipe cost via `yieldedCogs`.
- `stocktakes` + `stocktake_lines` tables, `start_stocktake`, `submit_stocktake` RPCs.
- `purchases.payment_status` (`cash`,`bank`,`credit`), `cash_account_id`; private bucket `purchase-attachments` + `purchase_attachments` table with RLS by `purchases.view`.
- UI in `src/modules/supply/` (InventoryLocations, TransfersPanel, RecipeEditor, StocktakePage, PurchaseAttachments) as tabs in `src/modules/shell/hubs.ts`.
