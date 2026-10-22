/**
 * Cashback levels (owner's rule 2026-10-22). Mirrors public._cashback_accrue:
 * spend builds up, each level reached pays its reward, and after the last
 * level the customer starts again from level 1.
 */
export type CashbackTier = { target: number; reward: number };

export type CashbackConfig = {
  enabled: boolean;
  tiers: CashbackTier[];
  target_amount: number;
  reward_amount: number;
};

/** Reads the server config; old configs without `tiers` become one level. */
export function parseCashbackConfig(raw: unknown): CashbackConfig {
  const v = (raw ?? {}) as Record<string, unknown>;
  const target = Number(v["target_amount"] ?? 0);
  const reward = Number(v["reward_amount"] ?? 0);
  const list = Array.isArray(v["tiers"]) ? (v["tiers"] as Record<string, unknown>[]) : [];
  const tiers = list
    .map((t) => ({ target: Number(t["target"] ?? 0), reward: Number(t["reward"] ?? 0) }))
    .filter((t) => t.target > 0 && t.reward > 0);
  return {
    enabled: Boolean(v["enabled"]),
    tiers: tiers.length > 0 ? tiers : target > 0 && reward > 0 ? [{ target, reward }] : [],
    target_amount: target,
    reward_amount: reward,
  };
}

/** Empty string when the levels are valid, otherwise the problem (Arabic or English). */
export function tierError(tiers: CashbackTier[], lang: "ar" | "en"): string {
  const ar = lang === "ar";
  if (tiers.length === 0) return ar ? "ضيف مستوى واحد على الأقل." : "Add at least one level.";
  let prev = 0;
  for (const [i, t] of tiers.entries()) {
    const n = i + 1;
    if (!(t.target > 0) || !(t.reward > 0)) return ar ? `المستوى ${n}: اكتب التارجت والمكافأة.` : `Level ${n}: enter the target and the reward.`;
    if (t.target <= prev) return ar ? `المستوى ${n}: التارجت لازم يكون أكبر من اللي قبله.` : `Level ${n}: the target must be bigger than the one before.`;
    if (t.reward >= t.target) return ar ? `المستوى ${n}: المكافأة لازم تكون أقل من التارجت.` : `Level ${n}: the reward must be smaller than the target.`;
    prev = t.target;
  }
  return "";
}

/** Adds `spend` and returns what is earned plus the new progress and level (0-based). */
export function accrueCashback(tiers: CashbackTier[], progress: number, level: number, spend: number) {
  if (tiers.length === 0 || spend <= 0) return { earned: 0, progress, level };
  let p = progress + spend;
  let l = Math.min(Math.max(level, 0), tiers.length - 1);
  let earned = 0;
  for (let guard = 0; guard < 1000; guard++) {
    const tier = tiers[l]!;
    if (p < tier.target) break;
    earned += tier.reward;
    l += 1;
    if (l >= tiers.length) {
      p -= tier.target;
      l = 0;
    }
  }
  return { earned: Math.round(earned * 100) / 100, progress: Math.round(p * 100) / 100, level: l };
}

/** The level the customer is working toward and how much is left. */
export function nextTier(tiers: CashbackTier[], progress: number, level: number) {
  if (tiers.length === 0) return null;
  const index = Math.min(Math.max(level, 0), tiers.length - 1);
  const tier = tiers[index]!;
  return { index, tier, left: Math.max(tier.target - progress, 0), done: Math.min(Math.max(progress / tier.target, 0), 1) };
}
