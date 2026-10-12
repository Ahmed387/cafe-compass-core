/** Unit families and conversion between entry units and an item's stock unit. */
const FACTORS: Record<string, { family: "mass" | "volume" | "count"; f: number }> = {
  g: { family: "mass", f: 1 },
  gm: { family: "mass", f: 1 },
  gram: { family: "mass", f: 1 },
  kg: { family: "mass", f: 1000 },
  ml: { family: "volume", f: 1 },
  l: { family: "volume", f: 1000 },
  liter: { family: "volume", f: 1000 },
  piece: { family: "count", f: 1 },
  pcs: { family: "count", f: 1 },
  pc: { family: "count", f: 1 },
  unit: { family: "count", f: 1 },
};

const norm = (u: string | null | undefined) => (u ?? "").trim().toLowerCase();

export const UNIT_LABEL: Record<string, string> = { g: "جم", kg: "كجم", ml: "مل", l: "لتر", piece: "قطعة" };

/** Units the user may enter for an item stocked in `stockUnit`. */
export function compatibleUnits(stockUnit: string): string[] {
  const fam = FACTORS[norm(stockUnit)]?.family;
  if (fam === "mass") return ["g", "kg"];
  if (fam === "volume") return ["ml", "l"];
  if (fam === "count") return ["piece"];
  return [stockUnit];
}

/** Convert qty in `from` to the item's `stockUnit`. Unknown units pass through. */
export function toStockUnit(qty: number, from: string, stockUnit: string): number {
  const a = FACTORS[norm(from)];
  const b = FACTORS[norm(stockUnit)];
  if (!a || !b || a.family !== b.family) return qty;
  return (qty * a.f) / b.f;
}

export function fromStockUnit(qty: number, to: string, stockUnit: string): number {
  return toStockUnit(qty, stockUnit, to);
}

export function defaultEntryUnit(stockUnit: string): string {
  const fam = FACTORS[norm(stockUnit)]?.family;
  return fam === "mass" ? "g" : fam === "volume" ? "ml" : fam === "count" ? "piece" : stockUnit;
}

export const unitLabel = (u: string) => UNIT_LABEL[norm(u)] ?? u;
