import { useState, type ReactNode } from "react";
import * as RadixDialog from "@radix-ui/react-dialog";
import { LogOut, Menu, PackagePlus, Table2, Users } from "lucide-react";
import {
  HydraProvider,
  SessionGate,
  LoginForm,
  OrderList,
  CreateOrderForm,
  RegisterUserForm,
  RegisterAdminForm,
  RequireRole,
  CancelOrderButton,
  OrderStatusControl,
  useSession,
  useLogout,
  useTenant,
  cn,
} from "../src";
import { useTheme } from "./useTheme";

/**
 * Derived from the CURRENT hostname, not a fixed origin.
 *
 * The tenant is whatever host the API request itself is addressed to, so a page served at
 * acme.localhost:5173 must call acme.localhost:8083. Hardcoding "localhost:8083" here would
 * send a host with no tenant label: every lookup returns `unknown` and every login fails
 * closed, while the UI looks perfectly fine. That is the single most likely way to get this
 * wrong, which is why the port is the only thing configurable.
 */
const AUTH_PORT = import.meta.env["VITE_HYDRA_AUTH_PORT"] ?? "8083";
const ORDERS_PORT = import.meta.env["VITE_HYDRA_ORDERS_PORT"] ?? "8082";

const AUTH_BASE_URL = `${window.location.protocol}//${window.location.hostname}:${AUTH_PORT}`;
const ORDERS_BASE_URL = `${window.location.protocol}//${window.location.hostname}:${ORDERS_PORT}`;

/**
 * Exactly three destinations, each backed by a capability that already exists. There is
 * no user-listing hook and no settings surface in this library, so a "Users" or
 * "Settings" entry would be a painted-on feature — FR-018 forbids it.
 *
 * Navigation is React state rather than a router: adding one would be a new runtime
 * dependency (FR-015), and FR-016 rules out routed dashboards anyway.
 */
type View = "orders" | "new-order" | "team";

const NAV: { view: View; label: string; icon: typeof Table2; adminOnly: boolean }[] = [
  { view: "orders", label: "Orders", icon: Table2, adminOnly: false },
  { view: "new-order", label: "New order", icon: PackagePlus, adminOnly: false },
  { view: "team", label: "Team", icon: Users, adminOnly: true },
];

const PAGE_TITLES: Record<View, { title: string; blurb: string }> = {
  orders: { title: "Orders", blurb: "Every order for this organization, newest first." },
  "new-order": { title: "New order", blurb: "Create an order for this organization." },
  team: { title: "Team", blurb: "Provision accounts for this organization." },
};

function ThemeToggle() {
  const { theme, toggle } = useTheme();
  return (
    <button
      onClick={toggle}
      aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} mode`}
      className="border-border-strong text-content hover:bg-surface-muted rounded-(--radius-control) border px-3 py-1.5 text-sm font-medium transition-colors"
    >
      {theme === "dark" ? "🌙" : "☀️"}
    </button>
  );
}

function NavList({ current, onNavigate }: { current: View; onNavigate: (v: View) => void }) {
  return (
    <nav className="flex flex-col gap-1" aria-label="Main">
      {NAV.map(({ view, label, icon: Icon, adminOnly }) => {
        const item = (
          <button
            key={view}
            onClick={() => onNavigate(view)}
            aria-current={current === view ? "page" : undefined}
            className={cn(
              "flex items-center gap-2.5 rounded-(--radius-control) px-3 py-2.5 text-sm font-medium",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand",
              "transition-colors",
              current === view
                ? "bg-brand-wash text-brand font-semibold"
                : "text-content-muted hover:bg-surface-muted hover:text-content",
            )}
          >
            <Icon aria-hidden="true" className="size-4 shrink-0" />
            {label}
          </button>
        );
        return adminOnly ? (
          <RequireRole key={view} role="ROLE_ADMIN">
            {item}
          </RequireRole>
        ) : (
          item
        );
      })}
    </nav>
  );
}

function Brand() {
  return (
    <div className="flex items-center gap-2.5 px-3 py-1">
      <span className="bg-brand text-brand-content grid size-7 place-items-center rounded-(--radius-control) text-sm font-bold">
        H
      </span>
      <span className="text-content text-base font-bold tracking-tight">Hydra</span>
    </div>
  );
}

function Shell({ children }: { children: ReactNode }) {
  const { user } = useSession();
  const tenant = useTenant();
  const { logout, isPending } = useLogout();
  const [view, setView] = useState<View>("orders");
  const [drawerOpen, setDrawerOpen] = useState(false);

  const page = PAGE_TITLES[view];

  function navigate(next: View) {
    setView(next);
    setDrawerOpen(false);
  }

  return (
    <div className="bg-surface-muted flex min-h-screen">
      {/* Persistent rail from `lg` up; below that the same list lives in the drawer. */}
      <aside className="bg-surface border-border-subtle hidden w-60 shrink-0 flex-col gap-6 border-r p-4 lg:flex">
        <Brand />
        <NavList current={view} onNavigate={navigate} />
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="bg-surface border-border-subtle flex h-16 items-center justify-between gap-3 border-b px-4 sm:px-6">
          <div className="flex min-w-0 items-center gap-3">
            <RadixDialog.Root open={drawerOpen} onOpenChange={setDrawerOpen}>
              <RadixDialog.Trigger asChild>
                <button
                  aria-label="Open navigation"
                  className="border-border-strong text-content hover:bg-surface-muted rounded-(--radius-control) border p-2 transition-colors lg:hidden"
                >
                  <Menu aria-hidden="true" className="size-4" />
                </button>
              </RadixDialog.Trigger>
              <RadixDialog.Portal>
                <RadixDialog.Overlay className="fixed inset-0 z-40 bg-black/50 lg:hidden" />
                {/* Radix supplies the focus trap, Escape handling, and focus restore to
                    the trigger — the parts of FR-019 that are easy to omit and
                    impossible to notice without a screen reader. */}
                <RadixDialog.Content
                  className={cn(
                    "bg-surface border-border-subtle shadow-overlay fixed inset-y-0 left-0 z-50",
                    "flex w-72 flex-col gap-6 border-r p-4 lg:hidden",
                    "motion-safe:data-[state=open]:animate-slide-in-left",
                  )}
                >
                  <RadixDialog.Title className="sr-only">Navigation</RadixDialog.Title>
                  <RadixDialog.Description className="sr-only">
                    Move between Orders, New order, and Team.
                  </RadixDialog.Description>
                  <Brand />
                  <NavList current={view} onNavigate={navigate} />
                </RadixDialog.Content>
              </RadixDialog.Portal>
            </RadixDialog.Root>

            <span className="text-content truncate text-sm font-semibold">
              {tenant.status === "recognized" ? tenant.displayName : "Hydra"}
            </span>
          </div>

          <div className="flex items-center gap-2 sm:gap-3">
            <span className="text-content-muted hidden text-sm sm:inline">{user?.username}</span>
            <ThemeToggle />
            <button
              onClick={() => void logout()}
              disabled={isPending}
              aria-label="Sign out"
              className="border-border-strong text-content hover:bg-surface-muted flex items-center gap-2 rounded-(--radius-control) border px-3 py-1.5 text-sm font-medium transition-colors disabled:opacity-60"
            >
              <LogOut aria-hidden="true" className="size-4" />
              <span className="hidden sm:inline">Sign out</span>
            </button>
          </div>
        </header>

        {/* Constrained column rather than full-bleed padding: long tables and forms stay
            readable on an ultrawide display. */}
        <main className="mx-auto flex w-full max-w-5xl flex-col gap-6 p-4 sm:p-6">
          <div className="flex flex-col gap-1">
            <h1 className="text-content text-2xl font-semibold tracking-tight">{page.title}</h1>
            <p className="text-content-muted text-sm">{page.blurb}</p>
          </div>
          {view === "orders" && (
            <OrderList
              rowActions={(order) => (
                <>
                  <OrderStatusControl order={order} />
                  <CancelOrderButton order={order} />
                </>
              )}
            />
          )}
          {view === "new-order" && <CreateOrderForm />}
          {view === "team" && (
            <RequireRole
              role="ROLE_ADMIN"
              fallback={
                <p className="text-content-muted text-sm">
                  You need an administrator account to provision users.
                </p>
              }
            >
              <div className="grid gap-6 lg:grid-cols-2">
                <RegisterUserForm />
                <RegisterAdminForm />
              </div>
            </RequireRole>
          )}
          {children}
        </main>
      </div>
    </div>
  );
}

export function App() {
  return (
    <HydraProvider apiBaseUrl={AUTH_BASE_URL} ordersBaseUrl={ORDERS_BASE_URL}>
      <SessionGate
        fallback={
          <div className="bg-surface-muted relative flex min-h-screen items-center justify-center p-4">
            <div className="absolute top-6 right-6">
              <ThemeToggle />
            </div>
            <LoginForm />
          </div>
        }
        pending={
          <div className="bg-surface-muted flex min-h-screen items-center justify-center">
            <p className="text-content-muted text-sm">Restoring your session…</p>
          </div>
        }
      >
        <Shell>{null}</Shell>
      </SessionGate>
    </HydraProvider>
  );
}
