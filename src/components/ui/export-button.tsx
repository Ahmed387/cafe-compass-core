import { Download, Loader2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { downloadCsv, stampedName, type CsvColumn } from "@/lib/csv";
import { useI18n } from "@/lib/i18n";

type Props<T> = {
  rows?: T[];
  /** When set, the full dataset is fetched on click instead of exporting the visible page. */
  fetchRows?: () => Promise<T[]>;
  columns: Array<CsvColumn<T>>;
  filePrefix: string;
  label?: string;
  disabled?: boolean;
  size?: "sm" | "default";
};

/** Shared export action: turns any table dataset into a downloadable CSV. */
export function ExportCsvButton<T>({
  rows,
  fetchRows,
  columns,
  filePrefix,
  label,
  disabled,
  size = "sm",
}: Props<T>) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const [busy, setBusy] = useState(false);

  const run = async () => {
    let data = rows ?? [];
    if (fetchRows) {
      setBusy(true);
      try {
        data = await fetchRows();
      } catch {
        setBusy(false);
        toast.error(ar ? "تعذر تجهيز الملف." : "Could not prepare the file.");
        return;
      }
      setBusy(false);
    }
    if (!data.length) {
      toast.error(ar ? "لا توجد بيانات للتصدير." : "No data to export.");
      return;
    }
    downloadCsv(data, columns, stampedName(filePrefix, "csv"));
    toast.success(ar ? "تم تنزيل الملف." : "File downloaded.");
  };

  return (
    <Button
      type="button"
      variant="outline"
      size={size}
      disabled={disabled || busy}
      className="gap-2 transition-all hover:shadow-md"
      onClick={() => void run()}
    >
      {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
      {label ?? (ar ? "تصدير CSV" : "Export CSV")}
    </Button>
  );
}
