export type ShiftSummaryExport = {
  shiftNumber: number;
  cashier: string;
  branch: string;
  fileDate: string;
  openedAt: string;
  closedAt: string;
  openingCash: number;
  cashSales: number;
  cardSales: number;
  pettyCashExpenses: number;
  expectedCash: number;
  actualCash: number;
  variance: number;
  invoiceCount: number;
  completedCount: number;
  refundedCount: number;
  refundTotal: number;
  currency: string;
};

export type ShiftInvoiceLineExport = {
  invoiceNumber: string;
  invoiceTime: string;
  paymentMethod: string;
  status: string;
  productName: string;
  category: string;
  modifiers: string;
  quantity: number;
  unitPrice: number;
  lineTotal: number;
  discount: number;
  grandTotal: number;
  notes: string;
  isRefunded: boolean;
  isCancelled: boolean;
};

const ARABIC_FONT = "Arial";
const HEADER_FILL = "FF0F766E";
const SUBHEADER_FILL = "FFCCFBF1";
const ACCENT_FILL = "FFFFEDD5";
const REFUND_FILL = "FFFEE2E2";
const CANCELLED_FILL = "FFF1F5F9";

function downloadBuffer(buffer: ArrayBuffer, fileName: string) {
  const blob = new Blob([buffer], {
    type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export async function exportClosedShiftWorkbook(
  summary: ShiftSummaryExport,
  lines: ShiftInvoiceLineExport[],
) {
  const ExcelJS = await import("exceljs");
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "20s Coffee";
  workbook.created = new Date();
  workbook.modified = new Date();

  const summarySheet = workbook.addWorksheet("ملخص الوردية", {
    views: [{ rightToLeft: true, showGridLines: false }],
    pageSetup: { orientation: "portrait", fitToPage: true, fitToWidth: 1 },
  });
  summarySheet.columns = [{ width: 34 }, { width: 28 }];
  summarySheet.mergeCells("A1:B1");
  summarySheet.getCell("A1").value = `تقرير الوردية رقم ${summary.shiftNumber}`;
  summarySheet.getCell("A1").font = {
    name: ARABIC_FONT,
    size: 18,
    bold: true,
    color: { argb: "FFFFFFFF" },
  };
  summarySheet.getCell("A1").fill = {
    type: "pattern",
    pattern: "solid",
    fgColor: { argb: HEADER_FILL },
  };
  summarySheet.getCell("A1").alignment = { horizontal: "center", vertical: "middle" };
  summarySheet.getRow(1).height = 30;

  const addSection = (title: string) => {
    const row = summarySheet.addRow([title, ""]);
    summarySheet.mergeCells(row.number, 1, row.number, 2);
    row.getCell(1).font = { name: ARABIC_FONT, bold: true, color: { argb: "FF115E59" } };
    row.getCell(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: SUBHEADER_FILL } };
    row.getCell(1).alignment = { horizontal: "right" };
  };
  const addValue = (label: string, value: string | number, money = false) => {
    const row = summarySheet.addRow([label, value]);
    row.font = { name: ARABIC_FONT, size: 11 };
    row.getCell(1).font = { name: ARABIC_FONT, size: 11, bold: true };
    row.getCell(2).alignment = { horizontal: typeof value === "number" ? "left" : "right" };
    if (money)
      row.getCell(2).numFmt =
        `#,##0.00 "${summary.currency}";[Red](#,##0.00) "${summary.currency}";-`;
  };

  summarySheet.addRow([]);
  addSection("معلومات الوردية");
  addValue("رقم الوردية", summary.shiftNumber);
  addValue("اسم الكاشير", summary.cashier);
  addValue("الفرع", summary.branch);
  addValue("وقت الفتح", summary.openedAt);
  addValue("وقت الإغلاق", summary.closedAt);
  summarySheet.addRow([]);
  addSection("حركة النقدية والدرج");
  addValue("رصيد بداية الدرج (عُهدة البداية)", summary.openingCash, true);
  addValue("إجمالي المبيعات النقدية", summary.cashSales, true);
  addValue("إجمالي مبيعات الفيزا / الدفع الإلكتروني", summary.cardSales, true);
  addValue("إجمالي المصروفات النثرية", summary.pettyCashExpenses, true);
  addValue("النقدية المتوقعة في الدرج", summary.expectedCash, true);
  addValue("النقدية الفعلية عند الإغلاق", summary.actualCash, true);
  addValue("الفارق / العجز والزيادة", summary.variance, true);
  summarySheet.addRow([]);
  addSection("مؤشرات الأداء");
  addValue("إجمالي عدد الفواتير", summary.invoiceCount);
  addValue("عدد الفواتير المكتملة", summary.completedCount);
  addValue("عدد الفواتير المرتجعة", summary.refundedCount);
  addValue("إجمالي قيمة المرتجعات", summary.refundTotal, true);

  summarySheet.eachRow((row) => {
    row.eachCell((cell) => {
      cell.font = { ...cell.font, name: ARABIC_FONT };
      cell.alignment = { ...cell.alignment, vertical: "middle", readingOrder: "rtl" };
      cell.border = {
        bottom: { style: "hair", color: { argb: "FFE2E8F0" } },
      };
    });
  });

  const details = workbook.addWorksheet("تفاصيل الفواتير والمنتجات", {
    views: [{ rightToLeft: true, state: "frozen", ySplit: 1, showGridLines: false }],
    pageSetup: { orientation: "landscape", fitToPage: true, fitToWidth: 1 },
  });
  details.columns = [
    { header: "رقم الفاتورة", key: "invoiceNumber", width: 16 },
    { header: "وقت الفاتورة", key: "invoiceTime", width: 22 },
    { header: "طريقة الدفع", key: "paymentMethod", width: 22 },
    { header: "حالة الفاتورة", key: "status", width: 16 },
    { header: "المنتج المباع", key: "productName", width: 28 },
    { header: "التصنيف", key: "category", width: 20 },
    { header: "الإضافات المختارة", key: "modifiers", width: 34 },
    { header: "الكمية", key: "quantity", width: 11 },
    { header: "سعر الوحدة", key: "unitPrice", width: 16 },
    { header: "إجمالي السطر", key: "lineTotal", width: 16 },
    { header: "قيمة الخصم", key: "discount", width: 16 },
    { header: "إجمالي الفاتورة النهائي", key: "grandTotal", width: 21 },
    { header: "الملاحظات / سبب المرتجع", key: "notes", width: 40 },
  ];
  details.autoFilter = { from: "A1", to: "M1" };
  details.getRow(1).height = 28;
  details.getRow(1).eachCell((cell) => {
    cell.font = { name: ARABIC_FONT, bold: true, color: { argb: "FFFFFFFF" } };
    cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: HEADER_FILL } };
    cell.alignment = {
      horizontal: "center",
      vertical: "middle",
      readingOrder: "rtl",
      wrapText: true,
    };
  });

  for (const line of lines) {
    const row = details.addRow(line);
    row.font = { name: ARABIC_FONT, size: 10 };
    row.alignment = { vertical: "middle", readingOrder: "rtl", wrapText: true };
    for (const key of ["unitPrice", "lineTotal", "discount", "grandTotal"] as const) {
      row.getCell(key).numFmt =
        `#,##0.00 "${summary.currency}";[Red](#,##0.00) "${summary.currency}";-`;
    }
    row.getCell("quantity").numFmt = "#,##0;(#,##0);-";
    if (line.isRefunded || line.isCancelled) {
      const color = line.isRefunded ? REFUND_FILL : CANCELLED_FILL;
      row.eachCell((cell) => {
        cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: color } };
      });
    } else if (row.number % 2 === 0) {
      row.eachCell((cell) => {
        cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: ACCENT_FILL } };
      });
    }
  }

  details.eachRow((row) => {
    row.eachCell((cell) => {
      cell.border = {
        bottom: { style: "hair", color: { argb: "FFCBD5E1" } },
        left: { style: "hair", color: { argb: "FFE2E8F0" } },
      };
    });
  });

  const output = await workbook.xlsx.writeBuffer();
  downloadBuffer(output as ArrayBuffer, `shift-${summary.shiftNumber}-${summary.fileDate}.xlsx`);
}
