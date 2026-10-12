import {
  BadgePercent,
  ClipboardCheck,
  Coins,
  FlaskConical,
  IdCard,
  KeyRound,
  NotebookTabs,
  PackageX,
  ReceiptText,
  ScrollText,
  BarChart3,
  BookOpen,
  Boxes,
  Coffee,
  Handshake,
  Landmark,
  LineChart,
  LayoutDashboard,
  QrCode,
  Receipt,
  Settings,
  ShieldCheck,
  ShoppingCart,
  Truck,
  Warehouse,
  Undo2,
  Wallet,
} from "lucide-react";

/**
 * The five navigation hubs. Each hub is one sidebar link; its tabs are the
 * existing pages, reached by client-side links so the app never reloads.
 */
export type HubTab = {
  to: string;
  labelKey: string;
  icon: typeof LayoutDashboard;
  permission?: string;
  superAdminOnly?: boolean;
  /** Also visible to signed-in partners, who only ever see their own share. */
  partnerVisible?: boolean;
  /** Extra permissions that also unlock the tab. */
  anyPermission?: string[];
};

export type Hub = {
  id: "operations" | "supply" | "finance" | "catalog" | "governance";
  /** Entry URL of the hub; opens the first tab the user may see. */
  path: "/operations" | "/supply" | "/finance" | "/menu-studio" | "/governance";
  labelKey: string;
  icon: typeof LayoutDashboard;
  tabs: HubTab[];
  /** Detail pages that belong to this hub without being a tab. */
  extraPrefixes?: string[];
};

export const HUBS: Hub[] = [
  {
    id: "operations",
    path: "/operations",
    labelKey: "hub.operations",
    icon: ShoppingCart,
    tabs: [
      { to: "/pos", labelKey: "nav.pos", icon: ShoppingCart, permission: "pos.view" },
      { to: "/orders", labelKey: "nav.orders", icon: Receipt, permission: "pos.view" },
      { to: "/refunds", labelKey: "nav.refunds", icon: Undo2, permission: "pos.view" },
    ],
    extraPrefixes: ["/shifts"],
  },
  {
    id: "supply",
    path: "/supply",
    labelKey: "hub.supply",
    icon: Boxes,
    tabs: [
      { to: "/inventory", labelKey: "nav.inventory", icon: Boxes, permission: "inventory.view" },
      {
        to: "/warehouse",
        labelKey: "nav.warehouse",
        icon: Warehouse,
        permission: "inventory.view",
      },
      { to: "/recipes", labelKey: "nav.recipes", icon: FlaskConical, permission: "inventory.view" },
      {
        to: "/stocktake",
        labelKey: "nav.stocktake",
        icon: ClipboardCheck,
        permission: "inventory.view",
      },
      { to: "/purchases", labelKey: "nav.purchases", icon: Truck, permission: "purchases.view" },
      { to: "/returns", labelKey: "nav.returns", icon: PackageX, permission: "purchases.view" },
    ],
  },
  {
    id: "finance",
    path: "/finance",
    labelKey: "hub.finance",
    icon: Wallet,
    tabs: [
      { to: "/money", labelKey: "nav.money", icon: Landmark, permission: "expenses.view" },
      { to: "/expenses", labelKey: "nav.expenses", icon: ReceiptText, permission: "expenses.view" },
      {
        to: "/pnl",
        labelKey: "nav.pnl",
        icon: LineChart,
        permission: "reports.profit",
        anyPermission: ["partners.view_profit"],
      },
      { to: "/insights", labelKey: "nav.insights", icon: BarChart3, permission: "reports.sales" },
    ],
    extraPrefixes: ["/treasury"],
  },
  {
    id: "catalog",
    path: "/menu-studio",
    labelKey: "hub.catalog",
    icon: Coffee,
    tabs: [
      { to: "/menu-studio", labelKey: "nav.menu", icon: Coffee, permission: "products.view" },
      { to: "/offers", labelKey: "nav.offers", icon: BadgePercent, permission: "products.view" },
      { to: "/loyalty", labelKey: "nav.loyalty", icon: Coins, permission: "loyalty.view" },
      { to: "/qr", labelKey: "nav.qr", icon: QrCode, permission: "products.view" },
    ],
  },
  {
    id: "governance",
    path: "/governance",
    labelKey: "hub.governance",
    icon: ShieldCheck,
    tabs: [
      { to: "/dashboard", labelKey: "nav.dashboard", icon: LayoutDashboard },
      {
        to: "/partners",
        labelKey: "nav.partners",
        icon: Handshake,
        permission: "partners.view",
        partnerVisible: true,
      },
      {
        to: "/partner-tabs",
        labelKey: "nav.partnerTabs",
        icon: NotebookTabs,
        permission: "partners.view",
        partnerVisible: true,
      },
      {
        to: "/hr",
        labelKey: "nav.hr",
        icon: IdCard,
        permission: "payroll.view",
        anyPermission: ["users.view"],
        partnerVisible: true,
      },
      { to: "/roles", labelKey: "nav.roles", icon: KeyRound, permission: "users.manage_roles" },
      { to: "/audit", labelKey: "nav.audit", icon: ScrollText, permission: "audit.view" },
      { to: "/settings", labelKey: "nav.settings", icon: Settings, permission: "settings.view" },
      { to: "/guide", labelKey: "nav.guide", icon: BookOpen, superAdminOnly: true },
    ],
    extraPrefixes: ["/staff", "/users"],
  },
];

const matches = (path: string, prefix: string) => path === prefix || path.startsWith(`${prefix}/`);

/** The hub that owns a URL, if any. */
export function hubForPath(path: string): Hub | undefined {
  return HUBS.find(
    (hub) =>
      matches(path, hub.path) ||
      hub.tabs.some((tab) => matches(path, tab.to)) ||
      (hub.extraPrefixes ?? []).some((prefix) => matches(path, prefix)),
  );
}

export function isTabActive(path: string, tab: HubTab) {
  return matches(path, tab.to);
}
