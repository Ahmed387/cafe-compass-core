// Groups public.product_sales_breakdown rows (product + size + price sold at)
// into one block per product: its totals, then each size and the prices it
// was sold at. Only clean sales reach here (no refund, no cancellation).

export type ProductSaleRow = {
  product: string;
  size: string;
  price: number | string;
  qty: number | string;
  revenue: number | string;
  cost: number | string | null;
  profit: number | string | null;
};

export type ProductSaleGroup = {
  product: string;
  qty: number;
  revenue: number;
  cost: number | null;
  profit: number | null;
  lines: Array<{
    size: string;
    price: number;
    qty: number;
    revenue: number;
    cost: number | null;
    profit: number | null;
  }>;
};

const n = (value: unknown) => {
  const num = Number(value ?? 0);
  return Number.isFinite(num) ? num : 0;
};
const round2 = (value: number) => Math.round(value * 100) / 100;
const orNull = (value: unknown) => (value === null || value === undefined ? null : n(value));

/** One block per product, best seller (by money) first; inside, sizes A→Z then highest price first. */
export function groupProductSales(rows: ProductSaleRow[]): ProductSaleGroup[] {
  const map = new Map<string, ProductSaleGroup>();
  for (const row of rows) {
    const key = row.product;
    const group = map.get(key) ?? {
      product: key,
      qty: 0,
      revenue: 0,
      cost: null,
      profit: null,
      lines: [],
    };
    const cost = orNull(row.cost);
    const profit = orNull(row.profit);
    group.qty += n(row.qty);
    group.revenue = round2(group.revenue + n(row.revenue));
    if (cost !== null) group.cost = round2((group.cost ?? 0) + cost);
    if (profit !== null) group.profit = round2((group.profit ?? 0) + profit);
    group.lines.push({
      size: row.size ?? "",
      price: n(row.price),
      qty: n(row.qty),
      revenue: n(row.revenue),
      cost,
      profit,
    });
    map.set(key, group);
  }
  const groups = [...map.values()];
  for (const g of groups) {
    g.lines.sort((a, b) => a.size.localeCompare(b.size) || b.price - a.price);
  }
  return groups.sort((a, b) => b.revenue - a.revenue || a.product.localeCompare(b.product));
}
