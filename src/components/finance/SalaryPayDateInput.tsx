import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

import { cafeToday } from "./pay-salary";

/** "Pay date" box next to every salary payout: today by default, any past day allowed. */
export function SalaryPayDateInput({
  value,
  onChange,
  lang,
  id = "salary-pay-date",
}: {
  value: string;
  onChange: (value: string) => void;
  lang: "ar" | "en";
  id?: string;
}) {
  return (
    <div className="grid gap-1">
      <Label htmlFor={id} className="text-xs">
        {lang === "ar" ? "تاريخ الصرف" : "Pay date"}
      </Label>
      <Input
        id={id}
        type="date"
        className="h-8 w-40"
        max={cafeToday()}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}
