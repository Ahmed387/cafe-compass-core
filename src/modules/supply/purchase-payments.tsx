import { useQuery } from "@tanstack/react-query";
import { FileText, Paperclip } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";

export type PaymentTerms = "cash" | "bank" | "credit";
export type PaySource = "treasury" | "drawer" | "bank";

export const ATTACHMENT_BUCKET = "purchase-attachments";

export const TERMS_LABEL: Record<PaymentTerms, string> = {
  cash: "كاش",
  bank: "تحويل بنكي",
  credit: "آجل",
};

export const SOURCE_LABEL: Record<PaySource, string> = {
  treasury: "الخزينة",
  drawer: "درج الوردية",
  bank: "تحويل بنكي",
};

/** Upload a receipt/invoice and attach it to the purchase. */
export async function attachPurchaseFile(companyId: string, purchaseId: string, file: File) {
  const ext = file.name.split(".").pop()?.toLowerCase() || "bin";
  const path = `${companyId}/${purchaseId}/${Date.now()}.${ext}`;
  const up = await supabase.storage
    .from(ATTACHMENT_BUCKET)
    .upload(path, file, file.type ? { contentType: file.type } : {});
  if (up.error) throw up.error;
  const { error } = await supabase.rpc("set_purchase_meta", {
    _purchase_id: purchaseId,
    _attachment_path: path,
  });
  if (error) throw error;
}

/** Pay a purchase from the treasury, the bank, or the open shift drawer. */
export async function payPurchase(purchaseId: string, amount: number, source: PaySource, notes?: string) {
  const { error } = await supabase.rpc("pay_purchase", {
    _purchase_id: purchaseId,
    _amount: amount,
    _source: source,
    ...(notes ? { _notes: notes } : {}),
  });
  if (error) throw error;
}

export function ChoiceRow<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: Array<{ value: T; label: string }>;
  onChange: (v: T) => void;
}) {
  return (
    <div>
      <Label>{label}</Label>
      <div className="mt-1 flex flex-wrap gap-2">
        {options.map((o) => (
          <Button
            key={o.value}
            type="button"
            size="sm"
            variant={value === o.value ? "default" : "outline"}
            onClick={() => onChange(o.value)}
          >
            {o.label}
          </Button>
        ))}
      </div>
    </div>
  );
}

export function FilePicker({ file, onChange }: { file: File | null; onChange: (f: File | null) => void }) {
  return (
    <div>
      <Label>صورة / PDF الفاتورة</Label>
      <label className="mt-1 flex cursor-pointer items-center gap-2 rounded-md border border-dashed border-input px-3 py-2 text-sm text-muted-foreground hover:bg-muted">
        <Paperclip className="h-4 w-4" />
        <span className="truncate">{file ? file.name : "اختر ملفًا (حتى 10MB)"}</span>
        <input
          type="file"
          accept="image/*,application/pdf"
          className="hidden"
          onChange={(e) => onChange(e.target.files?.[0] ?? null)}
        />
      </label>
    </div>
  );
}

/** Opens the private attachment through a short-lived signed link. */
export function AttachmentLink({ path }: { path: string | null }) {
  if (!path) return <span className="text-xs text-muted-foreground">—</span>;
  const open = async () => {
    const { data, error } = await supabase.storage.from(ATTACHMENT_BUCKET).createSignedUrl(path, 300);
    if (error || !data) {
      toast.error(friendlyError(error, "ar"));
      return;
    }
    window.open(data.signedUrl, "_blank", "noopener");
  };
  return (
    <Button size="sm" variant="ghost" className="h-7 gap-1 px-2" onClick={open}>
      <FileText className="h-4 w-4" />
      {path.endsWith(".pdf") ? "PDF" : "صورة"}
    </Button>
  );
}

export function TermsBadge({ terms }: { terms: string | null }) {
  const t = (terms ?? "cash") as PaymentTerms;
  return <Badge variant={t === "credit" ? "destructive" : "outline"}>{TERMS_LABEL[t] ?? t}</Badge>;
}

export function SupplierPayablesPanel({ currency, lang }: { currency: string; lang: "ar" | "en" }) {
  const q = useQuery({
    queryKey: ["supplier-payables"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("supplier_payables");
      if (error) throw error;
      return data ?? [];
    },
  });
  const rows = q.data ?? [];
  const total = rows.reduce((s, r) => s + Number(r.due), 0);
  return (
    <div className="rounded-lg border border-border bg-card p-4">
      <div className="flex items-center justify-between">
        <p className="font-semibold">مديونيات الموردين (آجل)</p>
        <p className="font-bold tabular-nums text-destructive">{formatMoney(total, currency, lang)}</p>
      </div>
      {rows.length === 0 ? (
        <p className="mt-2 text-sm text-muted-foreground">لا توجد مديونيات مفتوحة.</p>
      ) : (
        <ul className="mt-2 divide-y divide-border text-sm">
          {rows.map((r) => (
            <li key={r.supplier_id} className="flex items-center justify-between py-1.5">
              <span>
                {r.supplier_name} <span className="text-xs text-muted-foreground">({r.open_count} فاتورة)</span>
              </span>
              <span className="tabular-nums text-destructive">{formatMoney(Number(r.due), currency, lang)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
