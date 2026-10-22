import { normalizeTender } from "@/core/finance/formulas";

/** Human name of a tender key for invoices, tables and exports. */
export function tenderLabel(key: string, lang: "ar" | "en") {
  const k = normalizeTender(key);
  const ar: Record<string, string> = { cash: "كاش", instapay: "إنستاباي", wallet: "محفظة", visa: "فيزا", points: "نقاط", partner_tab: "حساب شريك" };
  const en: Record<string, string> = { cash: "Cash", instapay: "InstaPay", wallet: "Wallet", visa: "Card", points: "Points", partner_tab: "Partner tab" };
  if (key === "cashback") return lang === "ar" ? "كاش باك" : "Cashback";
  return (lang === "ar" ? ar : en)[k] ?? key;
}
