/** CSV helpers used by the export buttons across reports, treasury and purchases. */

export type CsvColumn<T> = {
  header: string;
  value: (row: T) => string | number | null | undefined;
};

function escapeCell(value: string | number | null | undefined) {
  if (value === null || value === undefined) return "";
  const text = String(value);
  if (/[",\n;]/.test(text)) return `"${text.replace(/"/g, '""')}"`;
  return text;
}

export function buildCsv<T>(rows: T[], columns: Array<CsvColumn<T>>) {
  const head = columns.map((c) => escapeCell(c.header)).join(",");
  const body = rows.map((row) => columns.map((c) => escapeCell(c.value(row))).join(","));
  return [head, ...body].join("\r\n");
}

/** Triggers a client-side file download without navigating away from the page. */
export function downloadFile(content: string, fileName: string, mime: string) {
  const blob = new Blob([`\uFEFF${content}`], { type: `${mime};charset=utf-8` });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function downloadCsv<T>(rows: T[], columns: Array<CsvColumn<T>>, fileName: string) {
  downloadFile(buildCsv(rows, columns), fileName, "text/csv");
}

export function downloadJson(data: unknown, fileName: string) {
  downloadFile(JSON.stringify(data, null, 2), fileName, "application/json");
}

export function stampedName(prefix: string, ext: string) {
  const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-");
  return `${prefix}-${stamp}.${ext}`;
}
