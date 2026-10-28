/**
 * Rules for editing and cancelling stock movements on the inventory page.
 * The database (edit_stock_movement / void_stock_movement) checks the same;
 * these only decide which buttons show and what the dialog warns about.
 */
export type MovementRow = {
  movement_type: string;
  reference_type: string | null;
  voided_at: string | null;
  quantity: number | string;
};

const MANUAL_REFS = ["manual", "opening_balance"];
const VOIDABLE_TYPES = ["purchase", "adjustment", "waste"];

/** Typed by hand (not from a sale, an invoice or a stocktake) and still live. */
export function canEditMovement(row: MovementRow): boolean {
  return !row.voided_at && MANUAL_REFS.includes(row.reference_type ?? "manual");
}

export function canVoidMovement(row: MovementRow): boolean {
  return canEditMovement(row) && VOIDABLE_TYPES.includes(row.movement_type);
}

/** Stock of the item once the movement is taken out (can go below zero). */
export function stockAfterVoid(currentStock: number, movementQty: number | string): number {
  return Math.round((currentStock - Number(movementQty)) * 1000) / 1000;
}

/** The movements tab shows live rows only; the cancelled tab only cancelled ones. */
export function movementsForTab<T extends Pick<MovementRow, "voided_at">>(
  rows: T[],
  tab: string,
): T[] {
  return rows.filter((row) => (tab === "voided" ? Boolean(row.voided_at) : !row.voided_at));
}
