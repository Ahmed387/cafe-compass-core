/** Typing in the phone box searches after 3 digits; the search box after 2 characters. */
export const MIN_PHONE_DIGITS = 3;
export const MIN_QUERY_CHARS = 2;

/**
 * The text the till searches with: the explicit search box wins, otherwise the
 * phone field once it holds enough digits. Characters that break a PostgREST
 * `or()` filter are dropped.
 */
export function customerLookupTerm(query: string, phone: string): string {
  const q = query.trim().replace(/[%,()\\]/g, "");
  if (q.length >= MIN_QUERY_CHARS) return q;
  const digits = phone.replace(/\D/g, "");
  return digits.length >= MIN_PHONE_DIGITS ? digits : "";
}
