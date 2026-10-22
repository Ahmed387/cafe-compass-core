import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";

import { NAV_PERMISSIONS, canAccessRoute, landingRouteFor, personalAccess, routeAccessFor } from "../../src/lib/nav-access.ts";
import { HUBS, hubForPath } from "../../src/modules/shell/hubs.ts";

const ROUTES = new Set(
  readdirSync(new URL("../../src/routes/_authenticated/", import.meta.url))
    .filter((f) => f.endsWith(".tsx") && f !== "route.tsx")
    .map((f) => "/" + f.replace(/\.tsx$/, "").replace(/\.index$/, "").replace(/\.\$[^.]+$/, "")),
);
const routeExists = (path: string) => ROUTES.has(path);

test("every page in the role map really exists", () => {
  for (const [role, paths] of Object.entries(NAV_PERMISSIONS)) {
    for (const path of paths) {
      if (path === "*") continue;
      assert.ok(routeExists(path), `${role} → ${path} has no page`);
    }
  }
});

test("every hub tab and hub entry is a real page", () => {
  for (const hub of HUBS) {
    assert.ok(routeExists(hub.path), `hub ${hub.id} → ${hub.path}`);
    for (const tab of hub.tabs) assert.ok(routeExists(tab.to), `hub ${hub.id} tab → ${tab.to}`);
  }
  assert.ok(existsSync(new URL("../../src/routes/menu.tsx", import.meta.url)), "public menu page");
});

// Old URLs kept only to forward to their new page.
const isRedirect = (path: string) =>
  /beforeLoad: \(\) => \{\s*throw redirect/.test(
    readFileSync(new URL(`../../src/routes/_authenticated${path}.tsx`, import.meta.url), "utf8"),
  );

test("every page belongs to a hub (so it shows in navigation)", () => {
  const standalone = new Set(["/dashboard", "/pos", "/settings", "/guide"]);
  const orphans = [...ROUTES].filter((p) => !hubForPath(p) && !standalone.has(p) && !isRedirect(p));
  assert.deepEqual(orphans.sort(), [], `pages outside every hub: ${orphans.join(", ")}`);
});

test("cashier reaches the till and own shifts, never money pages", () => {
  const cashier = routeAccessFor(["Cashier"]);
  assert.ok(canAccessRoute(cashier, "/pos"));
  assert.ok(canAccessRoute(cashier, "/orders/123"));
  for (const p of ["/money", "/treasury", "/pnl", "/hr", "/users", "/partners", "/audit"]) {
    assert.equal(canAccessRoute(cashier, p), false, p);
  }
  assert.equal(landingRouteFor(cashier, "/money"), "/pos");
});

test("manager reaches the add-ons page but not the treasury", () => {
  const manager = routeAccessFor(["Manager"]);
  assert.ok(canAccessRoute(manager, "/addons"));
  assert.ok(canAccessRoute(manager, "/dashboard"));
  assert.ok(canAccessRoute(manager, "/settings"));
  assert.equal(canAccessRoute(manager, "/treasury"), false);
});

test("super admin reaches everything; no role reaches nothing", () => {
  assert.ok(canAccessRoute(routeAccessFor(["Super Admin"]), "/audit"));
  assert.equal(canAccessRoute(routeAccessFor([]), "/pos"), false);
});

test("a silent partner never sees salaries or the treasury, even with the Partner role", () => {
  const access = routeAccessFor(["Partner"]);
  const me = { roleNames: ["Partner"], partnerTier: "silent", navOverrides: {} };
  assert.equal(personalAccess(me, access, "/hr"), false);
  assert.equal(personalAccess(me, access, "/treasury"), false);
  assert.ok(personalAccess(me, access, "/pnl"));
  // A Super Admin override wins over the tier.
  assert.ok(personalAccess({ ...me, navOverrides: { "/hr": true } }, access, "/hr"));
});
