# Orders and Notifications Refinement Plan

## Goal
Make the Orders screen faster to scan and operate, show financially accurate net collections without changing historical sales, and make notifications actionable.

## Orders table
- Show only the compact invoice sequence in the number column.
- Add a customer column after date/time, using the saved customer name or a muted “walk-in / cash customer” fallback.
- Add a 300ms debounced search that matches order number, customer name/phone, item name, cashier, and flexible displayed date/time values while preserving server-side pagination.
- Add row double-click to open order details, while keeping row buttons independently clickable.
- Apply explicit status treatments: green completed, pulsing amber pending, red refunded/partially refunded, and neutral gray cancelled.
- Fetch active refund totals with each order and display net collected as `total - refunded`, with the original total and refund amount beneath when applicable.

## Order details and refunds
- Reorganize order details into a clear header, item table, financial summary, highlighted net-collected total, and refund-history section.
- Include customer, cashier, status, date/time, quantities, unit prices, and line totals.
- Expand refund history data to show refunded items, quantities, waste versus returned-to-stock disposition, reason, payment method, and timestamp.
- Redesign the refund form with selectable line-item checkboxes, large quantity controls, and clear radio choices for operational waste or stock return.
- Keep all refund calculations and writes on the existing atomic refund workflow; no historical order totals will be overwritten.

## Notification navigation
- Read each notification’s structured data and type to determine its destination.
- Mark only the clicked notification as read, close the menu, then navigate to Orders, Finance, Shifts, or Refunds.
- Add an order deep-link search parameter so an order notification can load and open the matching order details automatically.
- Provide `/shifts` as a valid app destination that forwards to the existing Shifts tab under Orders.
- Fall back safely for older notifications that contain no supported entity link.

## Technical details
- Extend the Orders route search validation with an optional order identifier while preserving the existing Shifts tab parameter.
- Query active `order_refunds` alongside orders so totals and history use authoritative refund records.
- Use existing design-system controls and semantic colors; do not change database schema or financial records.
- Add any required bilingual labels to the existing translation dictionary.

## Verification
- Check Orders #1 and #3 against current refund records, including #3 showing 80.00 EGP net from 160.00 gross and 80.00 refunded.
- Verify order-number, customer, item, cashier, and date/time search; row double-click; status colors; refund controls; and notification destinations in the live preview.
- Confirm the preview build reports zero TypeScript/build errors.