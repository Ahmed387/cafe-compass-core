export type ExtraModifier = { option_id: string; name: string; price_delta: number };
type Line = { key: string; quantity: number; modifiers: ExtraModifier[] };

/**
 * Toggle an extra (sauce, shot…) on ONE unit of a cart line.
 *
 * - A line with several units is split: one unit moves to its own line with the
 *   extra, the rest stay as they were.
 * - The changed line always gets a new key. Lines are merged by key when the
 *   same product is tapped again, so keeping the old key would let the next tap
 *   land on the line that has the extra and give it to the new unit too.
 *
 * Returns the new cart and the key of the line that now carries the change.
 */
export function toggleExtraOnOneUnit<T extends Line>(
  cart: T[],
  lineKey: string,
  mod: ExtraModifier,
  newKey: string,
): { cart: T[]; key: string } {
  const target = cart.find((l) => l.key === lineKey);
  if (!target) return { cart, key: lineKey };
  const modifiers = target.modifiers.some((m) => m.option_id === mod.option_id)
    ? target.modifiers.filter((m) => m.option_id !== mod.option_id)
    : [...target.modifiers, mod];
  const next = cart.flatMap((l) => {
    if (l.key !== target.key) return [l];
    const changed = { ...l, key: newKey, quantity: 1, modifiers };
    return l.quantity > 1 ? [{ ...l, quantity: l.quantity - 1 }, changed] : [changed];
  });
  return { cart: next, key: newKey };
}
