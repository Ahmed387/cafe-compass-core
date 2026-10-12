import { Link, useRouter, useRouterState } from "@tanstack/react-router";
import {
  Bell,
  X,
  ClipboardList,
  Coffee,
  Receipt,
  ShoppingCart,
  Handshake,
  LayoutDashboard,
  LogOut,
  Menu,
  Settings,
  ShieldCheck,
  Users,
  CalendarRange,
  Landmark,
  Undo2,
  Boxes,
  Truck,
  Wallet,
  BarChart3,
  QrCode,
  BadgePercent,
  Gift,
  Sparkles,
  PanelLeftClose,
  PanelLeftOpen,
  BookOpen,
  ChevronDown,
  Languages,
  Inbox,
  type LucideIcon,
} from "lucide-react";

import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { useAuth } from "@/lib/auth";
import { useI18n } from "@/lib/i18n";
import { HubTabs } from "@/modules/shell/HubTabs";
import { hubForPath, type Hub } from "@/modules/shell/hubs";
import { useHubAccess } from "@/modules/shell/use-hub-access";

import { useNotifications } from "@/lib/use-notifications";

export function AppShell({ children }: { children: ReactNode }) {
  const { t, lang, setLang } = useI18n();
  const { me, currentBranchId, setCurrentBranchId, signOut } = useAuth();
  const router = useRouter();
  const [mobileOpen, setMobileOpen] = useState(false);
  const { unread, notifications, markAllRead, markRead, dismiss, clearAll } = useNotifications();
  const [removing, setRemoving] = useState<string[]>([]);
  const [notificationsOpen, setNotificationsOpen] = useState(false);

  // Play the exit animation before the row actually disappears from the list.
  function removeOne(id: string) {
    setRemoving((prev) => [...prev, id]);
    window.setTimeout(() => {
      dismiss(id);
      setRemoving((prev) => prev.filter((value) => value !== id));
    }, 180);
  }

  const [collapsed, setCollapsed] = useState(false);

  useEffect(() => {
    setCollapsed(window.localStorage.getItem("sidebar-collapsed") === "1");
  }, []);

  function toggleCollapsed() {
    setCollapsed((prev) => {
      const next = !prev;
      window.localStorage.setItem("sidebar-collapsed", next ? "1" : "0");
      return next;
    });
  }

  const { hubs } = useHubAccess();
  const currentPath = router.state.location.pathname;
  const activeHubId = hubForPath(currentPath)?.id;

  // Module colours live on <html> so dialogs and popovers (portaled to <body>) match the page.
  useEffect(() => {
    const root = document.documentElement;
    if (activeHubId) root.dataset["module"] = activeHubId;
    else delete root.dataset["module"];
  }, [activeHubId]);

  const initials = (me?.profile.display_name || me?.profile.first_name || "?")
    .split(" ")
    .map((part) => part[0])
    .slice(0, 2)
    .join("")
    .toUpperCase();

  async function handleSignOut() {
    await signOut();
    router.navigate({ to: "/auth", replace: true });
  }

  function openNotification(item: (typeof notifications)[number]) {
    markRead(item.id);
    setNotificationsOpen(false);
    const data = item.data ?? {};
    const orderId = typeof data["order_id"] === "string" ? data["order_id"] : undefined;
    const explicitLink = typeof data["link"] === "string" ? data["link"] : undefined;

    if (item.type.startsWith("partner_tab.")) {
      router.navigate({ to: "/partner-tabs" });
    } else if (orderId || item.type.startsWith("order.")) {
      router.navigate({ to: "/orders", search: { orderId, tab: undefined } });
    } else if (explicitLink === "/refunds" || item.type.includes("refund")) {
      router.navigate({ to: "/refunds" });
    } else if (
      explicitLink === "/finance" ||
      item.type.startsWith("partner_") ||
      item.type.startsWith("expense.")
    ) {
      router.navigate({ to: "/money" });
    } else if (explicitLink === "/shifts" || item.type.startsWith("shift.")) {
      router.navigate({ to: "/shifts" });
    } else if (item.type.startsWith("period.") || item.type.startsWith("finance.")) {
      router.navigate({ to: "/pnl" });
    } else if (item.type.startsWith("inventory.")) {
      router.navigate({ to: "/inventory", search: { tab: "stock" } });
    }
  }

  const navLink = (hub: Hub, index: number, isCollapsed: boolean) => {
    const Icon = hub.icon;
    const active = activeHubId === hub.id;
    const base = `group relative flex animate-nav-in items-center gap-3 overflow-hidden rounded-xl py-2.5 text-sm transition-all duration-300 ${isCollapsed ? "justify-center px-2" : "px-3"}`;
    const link = (
      <Link
        key={hub.id}
        to={hub.tabs[0]?.to ?? hub.path}
        style={{ animationDelay: `${index * 30}ms` }}
        onClick={() => setMobileOpen(false)}
        aria-current={active ? "page" : undefined}
        className={
          active
            ? `${base} font-semibold bg-gradient-module text-white shadow-glow [&>span[data-chip]]:bg-white/20`
            : `${base} font-medium text-sidebar-foreground/75 hover:bg-sidebar-accent/70 hover:text-sidebar-accent-foreground hover:shadow-lg ${isCollapsed ? "" : "hover:translate-x-1 rtl:hover:-translate-x-1"}`
        }
      >
        <span
          data-chip
          data-module={hub.id}
          className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-sidebar-accent/50 transition-all duration-300 group-hover:bg-gradient-module group-hover:text-white"
        >
          <Icon className="size-4 transition-transform duration-300 group-hover:scale-110" />
        </span>
        {!isCollapsed && <span className="truncate">{t(hub.labelKey)}</span>}
      </Link>
    );
    if (!isCollapsed) return link;
    return (
      <Tooltip key={hub.id}>
        <TooltipTrigger asChild>{link}</TooltipTrigger>
        <TooltipContent side="right">{t(hub.labelKey)}</TooltipContent>
      </Tooltip>
    );
  };

  const navFor = (isCollapsed: boolean) => (
    <TooltipProvider delayDuration={200}>
      <nav className="flex flex-1 flex-col gap-1 overflow-y-auto p-3">
        {hubs.map((hub, index) => navLink(hub, index, isCollapsed))}
      </nav>
    </TooltipProvider>
  );

  return (
    <div className="flex min-h-screen bg-background">
      <aside
        className={`sticky top-0 hidden h-screen shrink-0 flex-col bg-gradient-sidebar text-sidebar-foreground shadow-2xl transition-[width] duration-300 lg:flex ${collapsed ? "w-[76px]" : "w-64"}`}
      >
        <div
          className={`flex items-center gap-3 border-b border-sidebar-border/60 py-4 ${collapsed ? "justify-center px-2" : "px-4"}`}
        >
          <span className="flex size-9 animate-float-slow items-center justify-center rounded-xl bg-gradient-accent text-sidebar-primary-foreground shadow-glow">
            <Coffee className="size-5" />
          </span>
          {!collapsed && (
            <div className="leading-tight">
              <p className="font-display text-sm font-bold tracking-tight">
                {me?.company?.name ?? t("app.name")}
              </p>
              <p className="text-xs text-sidebar-foreground/55">{t("app.name")}</p>
            </div>
          )}
        </div>
        {navFor(collapsed)}
        <div className="flex items-center justify-between gap-2 border-t border-sidebar-border/60 px-3 py-3 text-xs text-sidebar-foreground/55">
          {!collapsed && (
            <span className="inline-flex items-center gap-2 truncate">
              <span className="size-2 animate-pulse-glow rounded-full bg-success" />
              {me?.roleNames.join(" • ") || "—"}
            </span>
          )}
          <button
            type="button"
            onClick={toggleCollapsed}
            aria-label={collapsed ? t("nav.expand") : t("nav.collapse")}
            className="mx-auto flex size-8 items-center justify-center rounded-lg bg-sidebar-accent/40 text-sidebar-foreground/80 transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
          >
            {collapsed ? (
              <PanelLeftOpen className="size-4" />
            ) : (
              <PanelLeftClose className="size-4" />
            )}
          </button>
        </div>
      </aside>

      {mobileOpen && (
        <div className="fixed inset-0 z-40 lg:hidden">
          <button
            aria-label="Close navigation"
            className="absolute inset-0 bg-foreground/40"
            onClick={() => setMobileOpen(false)}
          />
          <aside className="absolute inset-y-0 start-0 flex w-64 flex-col animate-slide-in-start bg-gradient-sidebar text-sidebar-foreground shadow-2xl">
            <div className="border-b border-sidebar-border/60 px-4 py-4 text-sm font-bold">
              {me?.company?.name ?? t("app.name")}
            </div>
            {navFor(false)}
          </aside>
        </div>
      )}

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-30 flex flex-wrap items-center gap-2 border-b border-border bg-card/85 px-3 py-2.5 backdrop-blur-md sm:px-5">
          <Button
            variant="ghost"
            size="icon"
            className="lg:hidden"
            onClick={() => setMobileOpen(true)}
            aria-label="Open navigation"
          >
            <Menu className="size-5" />
          </Button>

          {me && me.branches.length > 1 && (
            <Select
              value={currentBranchId ?? ""}
              onValueChange={(value) => setCurrentBranchId(value)}
            >
              <SelectTrigger className="h-9 w-[170px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {me.branches.map((branch) => (
                  <SelectItem key={branch.id} value={branch.id}>
                    {branch.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}

          <div className="ms-auto flex items-center gap-1.5">
            <Button
              variant="outline"
              size="sm"
              className="h-9"
              onClick={() => setLang(lang === "en" ? "ar" : "en")}
            >
              <Languages className="size-4" />
              {lang === "en" ? "العربية" : "English"}
            </Button>

            <DropdownMenu open={notificationsOpen} onOpenChange={setNotificationsOpen}>
              <DropdownMenuTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon"
                  className="relative transition-all duration-200"
                  aria-label="Notifications"
                >
                  <Bell className="size-5" />
                  {unread > 0 && (
                    <span className="animate-pulse-glow absolute end-1 top-1 flex size-4 items-center justify-center rounded-full bg-destructive text-[10px] font-bold text-destructive-foreground">
                      {unread}
                    </span>
                  )}
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-80">
                <DropdownMenuLabel className="flex items-center justify-between gap-2">
                  <span>{lang === "ar" ? "الإشعارات" : "Notifications"}</span>
                  <span className="flex items-center gap-2">
                    {unread > 0 && (
                      <button className="text-xs underline" onClick={() => markAllRead()}>
                        {lang === "ar" ? "تعليم كمقروء" : "Mark all read"}
                      </button>
                    )}
                    {notifications.length > 0 && (
                      <button
                        className="text-xs text-destructive underline"
                        onClick={() => clearAll()}
                      >
                        {lang === "ar" ? "مسح كل الإشعارات" : "Clear all"}
                      </button>
                    )}
                  </span>
                </DropdownMenuLabel>
                <DropdownMenuSeparator />
                {notifications.length === 0 ? (
                  <p className="px-2 py-6 text-center text-sm text-muted-foreground">
                    {lang === "ar" ? "لا توجد إشعارات." : "No notifications yet."}
                  </p>
                ) : (
                  <div className="max-h-96 space-y-1 overflow-y-auto">
                    {notifications.slice(0, 8).map((item) => (
                      <div
                        key={item.id}
                        role="button"
                        tabIndex={0}
                        onClick={() => openNotification(item)}
                        onKeyDown={(event) => {
                          if (event.key === "Enter" || event.key === " ") openNotification(item);
                        }}
                        className={`animate-card-in flex cursor-pointer items-start gap-2 rounded-md px-2 py-2 text-sm transition-all duration-200 hover:bg-muted/60 ${
                          removing.includes(item.id)
                            ? "pointer-events-none translate-x-2 scale-95 opacity-0"
                            : "opacity-100"
                        }`}
                      >
                        <span className="min-w-0 flex-1">
                          <span
                            className={`block font-medium ${item.read_at ? "" : "text-foreground"}`}
                          >
                            {item.title}
                          </span>
                          {item.body && (
                            <span className="mt-0.5 block text-xs text-muted-foreground">
                              {item.body}
                            </span>
                          )}
                        </span>
                        <button
                          className="rounded-md p-1 text-muted-foreground transition-all duration-200 hover:bg-destructive/10 hover:text-destructive"
                          aria-label={lang === "ar" ? "مسح الإشعار" : "Dismiss notification"}
                          title={lang === "ar" ? "مسح الإشعار" : "Dismiss notification"}
                          onClick={(event) => {
                            event.preventDefault();
                            event.stopPropagation();
                            removeOne(item.id);
                          }}
                        >
                          <X className="size-3.5" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </DropdownMenuContent>
            </DropdownMenu>

            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="ghost" className="h-9 gap-2 px-2">
                  <span className="flex size-7 items-center justify-center rounded-full bg-primary text-xs font-bold text-primary-foreground">
                    {initials}
                  </span>
                  <span className="hidden text-start leading-tight sm:block">
                    <span className="block text-sm font-medium">
                      {me?.profile.display_name || me?.profile.first_name}
                    </span>
                    <span className="block text-xs text-muted-foreground">
                      {me?.roleNames[0] ?? "—"}
                    </span>
                  </span>
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-56">
                <DropdownMenuLabel>
                  <p className="text-sm font-medium">{me?.profile.email}</p>
                  <div className="mt-1 flex flex-wrap gap-1">
                    {me?.roleNames.map((role) => (
                      <Badge key={role} variant="secondary">
                        {role}
                      </Badge>
                    ))}
                  </div>
                </DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={handleSignOut}>
                  <LogOut className="size-4" />
                  {t("auth.signout")}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </header>

        <main
          key={router.state.location.pathname}
          className="min-w-0 flex-1 animate-fade-in bg-gradient-mesh p-4 sm:p-6"
        >
          <HubTabs />
          {children}
        </main>
      </div>
    </div>
  );
}

/** Icon of the nav tab (or hub) that owns a URL — every page header gets one for free. */
function routeIcon(path: string): LucideIcon | undefined {
  const hub = hubForPath(path);
  if (!hub) return undefined;
  const tab = [...hub.tabs]
    .sort((a, b) => b.to.length - a.to.length)
    .find((t) => path === t.to || path.startsWith(`${t.to}/`));
  return tab?.icon ?? hub.icon;
}

export function PageHeader({
  title,
  description,
  action,
  icon,
}: {
  title: string;
  description?: string | undefined;
  action?: ReactNode;
  icon?: LucideIcon | undefined;
}) {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const Icon = icon ?? routeIcon(pathname);
  return (
    <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
      <div className="flex min-w-0 animate-fade-in items-center gap-3">
        {Icon && (
          <span className="icon-chip size-11 animate-pop-in sm:size-12" aria-hidden>
            <Icon className="size-5 sm:size-6" />
          </span>
        )}
        <div className="min-w-0">
          <h1 className="font-display text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
            <span className="text-gradient-module">{title}</span>
          </h1>
          {description && <p className="mt-1 text-sm text-muted-foreground">{description}</p>}
        </div>
      </div>
      {action}
    </div>
  );
}

export function EmptyState({ message, action }: { message: string; action?: ReactNode }) {
  return (
    <div className="animate-scale-in rounded-xl border border-dashed border-primary/30 bg-card/50 p-10 text-center">
      <span className="icon-chip-soft mx-auto mb-3 size-12 animate-float-slow rounded-2xl" aria-hidden>
        <Inbox className="size-6" />
      </span>
      <p className="text-sm text-muted-foreground">{message}</p>
      {action && <div className="mt-4 flex justify-center">{action}</div>}
    </div>
  );
}

export function NoPermission({ message }: { message: string }) {
  return (
    <div className="card-surface animate-scale-in rounded-xl border p-10 text-center">
      <ShieldCheck className="mx-auto size-8 animate-float-slow text-muted-foreground" />
      <p className="mt-3 text-sm text-muted-foreground">{message}</p>
    </div>
  );
}
