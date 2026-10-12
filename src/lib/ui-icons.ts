import {
  AlertTriangle,
  ArrowLeft,
  ArrowLeftRight,
  ArrowRight,
  Ban,
  Banknote,
  BarChart3,
  Boxes,
  CalendarDays,
  Check,
  CheckCheck,
  CircleDollarSign,
  ClipboardCheck,
  ClipboardList,
  Clock,
  Coffee,
  Coins,
  Download,
  Eye,
  FileText,
  Gauge,
  Gavel,
  Gift,
  HandCoins,
  Handshake,
  History,
  KeyRound,
  Landmark,
  Link2,
  Loader2,
  Lock,
  LockOpen,
  LogIn,
  Package,
  PackageCheck,
  Pencil,
  Percent,
  PiggyBank,
  Plus,
  Power,
  PowerOff,
  Printer,
  Receipt,
  ReceiptText,
  RotateCcw,
  Save,
  Search,
  Send,
  Settings,
  ShieldCheck,
  ShoppingBag,
  ShoppingCart,
  Trash2,
  TrendingDown,
  TrendingUp,
  Truck,
  Undo2,
  Upload,
  UserRound,
  Users,
  Wallet,
  X,
  type LucideIcon,
} from "lucide-react";
import { Children, isValidElement, type ReactNode } from "react";

/**
 * One icon vocabulary for the whole app. Buttons, dialog titles, tabs and KPI
 * cards that only carry text get their icon from here, so the same word always
 * shows the same picture in Arabic and English.
 */

type Rule = [RegExp, LucideIcon];

const normalize = (text: string) =>
  text
    .replace(/[ً-ْـ]/g, "") // tashkeel & tatweel
    .replace(/[أإآ]/g, "ا")
    .replace(/ى/g, "ي")
    .replace(/ة/g, "ه")
    .replace(/^[\s+\-−•]+/, "")
    .trim()
    .toLowerCase();

/** Text-only children → their string, or null when they contain elements / emoji. */
export function plainText(children: ReactNode): string | null {
  let out = "";
  let ok = true;
  Children.forEach(children, (child) => {
    if (!ok) return;
    if (typeof child === "string" || typeof child === "number") out += String(child);
    else if (child == null || typeof child === "boolean") return;
    else if (isValidElement(child)) ok = false;
  });
  if (!ok || !out.trim()) return null;
  if (/\p{Extended_Pictographic}/u.test(out)) return null;
  return out;
}

/** Busy labels ("Saving…", "جارٍ الحفظ") show a spinner instead of a verb icon. */
const BUSY = /(…|\.\.\.)\s*$|^جار/;

// Verbs that win over any subject in the label ("Cancel advance" is still a cancel).
const STRONG_VERBS: Rule[] = [
  [/^(cancel|الغاء|الغ|تراجع|void)/, X],
  [/^(back|رجوع|ارجع|prev|السابق)/, ArrowLeft],
  [/^(next|التالي)/, ArrowRight],
  [/^(delete|remove|حذف|احذف|شيل|مسح|امسح|clear|wipe|yes, delete|نعم، احذف)/, Trash2],
  [/^(reject|رفض|ارفض)/, Ban],
  [/^(reverse|عكس)/, Undo2],
  [/^(sign in|log in|login|تسجيل الدخول|دخول)/, LogIn],
];

// Whole-label rules (specific phrases).
const ACTION_PHRASES: Rule[] = [
  [/close shift|اغلاق الورديه|قفل الورديه|تقفيل/, Lock],
  [/open shift|فتح الورديه|افتح ورديه/, LockOpen],
  [/add to (order|cart)|للطلب|للسله/, ShoppingCart],
  [/withdraw|طلب سحب/, HandCoins],
  [/advance|سلفه/, HandCoins],
  [/payroll|رواتب/, Wallet],
  [/development fund|\bfund\b|الصندوق/, PiggyBank],
  [/password|كلمه (السر|المرور)/, KeyRound],
  [/invoice|فاتوره/, ReceiptText],
  [/card|كارت/, Printer],
  [/select all|تحديد الكل/, CheckCheck],
  [/clear selection|الغاء التحديد/, X],
  [/suggested price|السعر المقترح/, Percent],
  [/stock bypass|تجاوز المخزون/, AlertTriangle],
  [/deduct|خصم من/, TrendingDown],
  [/\bnew\b|جديد/, Plus],
  [/reverse|عكس/, Undo2],
];

// First-word rules: the verb that starts the label.
const ACTION_VERBS: Rule[] = [
  [/^(cancel|الغاء|الغ|تراجع|void)/, X],
  [/^(back|رجوع|ارجع|prev|السابق)/, ArrowLeft],
  [/^(next|التالي)/, ArrowRight],
  [/^(delete|remove|حذف|احذف|شيل|مسح|امسح|clear|wipe|yes, delete|نعم، احذف)/, Trash2],
  [/^(save|حفظ|احفظ|تحديث وحفظ)/, Save],
  [/^(add|new|create|record|\+|اضافه|اضف|ضيف|جديد|انشاء|سجل|تسجيل)/, Plus],
  [/^(edit|تعديل|عدل|correct|تصحيح)/, Pencil],
  [/^(print|اطبع|طباعه)/, Printer],
  [/^(refund|return|استرجاع|مرتجع|ارجاع)/, Undo2],
  [/^(reject|رفض|ارفض)/, Ban],
  [/^(approve|confirm|apply|accept|موافقه|تاكيد|اكد|اعتماد|اعتمد|تطبيق|طبق|تنفيذ|نفذ|ok\b)/, Check],
  [/^(pay|صرف|اصرف|دفع|ادفع|سداد|سدد)/, Banknote],
  [/^(transfer|تحويل|حول)/, ArrowLeftRight],
  [/^(export|download|تصدير|تحميل|نزل)/, Download],
  [/^(upload|replace image|رفع|ارفع|استبدال)/, Upload],
  [/^(disable|deactivate|تعطيل|عطل|ايقاف|اوقف)/, PowerOff],
  [/^(enable|activate|تفعيل|فعل)/, Power],
  [/^(reset|تصفير|صفر|تهيئه)/, RotateCcw],
  [/^(sign in|login|دخول|تسجيل الدخول)/, LogIn],
  [/^(send|submit|ارسال|ارسل)/, Send],
  [/^(view|details|review|show|عرض|اعرض|تفاصيل|مراجعه|راجع)/, Eye],
  [/^(history|الحركات|السجل)/, History],
  [/^(deliver|تسليم|سلم)/, PackageCheck],
  [/^(link|ربط|اربط)/, Link2],
  [/^(search|بحث|ابحث)/, Search],
  [/^(make offer|عمل عرض|اعمل عرض)/, Gift],
  [/^(close|اغلاق|اقفل|قفل)/, X],
  [/^(generate|issue|اصدار|اصدر)/, FileText],
];

/** Icon for a button label, or null when nothing fits (category chips, numbers…). */
export function actionIcon(
  text: string,
): { icon: LucideIcon; spin?: boolean; flip?: boolean } | null {
  const s = normalize(text);
  if (!s || /^[\d\s.,%+-]+$/.test(s)) return null;
  if (BUSY.test(s)) return { icon: Loader2, spin: true };
  for (const [re, icon] of STRONG_VERBS) {
    if (re.test(s)) return { icon, flip: icon === ArrowLeft || icon === ArrowRight };
  }
  for (const [re, icon] of ACTION_PHRASES) if (re.test(s)) return { icon };
  for (const [re, icon] of ACTION_VERBS) {
    if (re.test(s)) return { icon, flip: icon === ArrowLeft || icon === ArrowRight };
  }
  return null;
}

// Subject rules for titles, tabs and KPI labels (the thing being shown).
const TOPICS: Rule[] = [
  [/cashback|كاش باك|كاشباك|محفظه|wallet/, Coins],
  [/advance|سلف/, HandCoins],
  [/penalt|جزاء|جزاءات|غرامه/, Gavel],
  [/bonus|مكافا|بونص/, Gift],
  [/waste|هالك|هدر/, Trash2],
  [/refund|return|مرتجع|استرجاع/, Undo2],
  [/net profit|صافي الربح|profit|ربح|ارباح/, TrendingUp],
  [/loss|خساره/, TrendingDown],
  [/payout|distribution|توزيع/, PiggyBank],
  [/development fund|صندوق/, PiggyBank],
  [/partner|شريك|شركاء/, Handshake],
  [/\btabs?\b|على الحساب|حساب مفتوح/, ReceiptText],
  [/salary|salaries|payroll|راتب|رواتب|مرتبات/, Wallet],
  [/expense|مصروف|مصاريف|مصروفات/, Receipt],
  [/revenue|sales|income|مبيعات|ايراد|دخل/, CircleDollarSign],
  [/cash|نقدي|كاش|درج|drawer/, Banknote],
  [/treasury|خزنه|خزينه|bank|بنك/, Landmark],
  [/supplier|مورد|موردين|purchase|مشتريات|شراء/, Truck],
  [/stocktake|جرد/, ClipboardCheck],
  [/stock|inventory|مخزون|مخزن|warehouse/, Boxes],
  [/recipe|وصفه|مكونات|ingredient/, Package],
  [/product|menu|منتج|صنف|اصناف|منيو/, Coffee],
  [/\borders?\b|اوردر|طلب|فاتوره|invoice/, ShoppingBag],
  [/shift|ورديه|ورديات/, Clock],
  [/hours|ساعات/, Clock],
  [/day|days|ايام|يوم|تاريخ|date|month|شهر/, CalendarDays],
  [/customer|عميل|عملاء|visit|زيار/, UserRound],
  [/staff|employee|user|موظف|موظفين|مستخدم/, Users],
  [/role|permission|صلاحي|اذن/, ShieldCheck],
  [/discount|offer|خصم|عرض|عروض|%/, Percent],
  [/average|avg|متوسط|margin|هامش|ratio|نسبه/, Gauge],
  [/report|تقرير|statement|كشف|analytics|تحليل/, BarChart3],
  [/setting|اعدادات/, Settings],
  [/audit|سجل|\blogs?\b/, ClipboardList],
  [/debt|مديوني|ديون|\bdue\b|مستحق/, AlertTriangle],
];

/** Icon for a subject label (dialog title, tab, KPI), or null. */
export function topicIcon(text: string): LucideIcon | null {
  const s = normalize(text);
  if (!s) return null;
  for (const [re, icon] of TOPICS) if (re.test(s)) return icon;
  return null;
}

/** Dialog / sheet titles: subject first, then the verb ("Edit …" → pencil). */
export function titleIcon(text: string): LucideIcon | null {
  return topicIcon(text) ?? actionIcon(text)?.icon ?? null;
}
