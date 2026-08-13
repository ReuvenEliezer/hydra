import {
  HydraProvider,
  SessionGate,
  LoginForm,
  OrderList,
  useSession,
  useLogout,
} from "../src";
import { useTheme } from "./useTheme";

const AUTH_BASE_URL = import.meta.env["VITE_HYDRA_AUTH_URL"] ?? "http://localhost:8083";
const ORDERS_BASE_URL = import.meta.env["VITE_HYDRA_ORDERS_URL"] ?? "http://localhost:8082";
const TENANT_ID =
  import.meta.env["VITE_HYDRA_TENANT_ID"] ?? "00000000-0000-0000-0000-000000000000";

function ThemeToggle() {
  const { theme, toggle } = useTheme();
  return (
    <button
      onClick={toggle}
      aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} mode`}
      className="border-border-subtle text-content hover:bg-surface-muted rounded-(--radius-control) border px-3 py-1.5 text-sm"
    >
      {theme === "dark" ? "🌙 Dark" : "☀️ Light"}
    </button>
  );
}

function Header() {
  const { user } = useSession();
  const { logout, isPending } = useLogout();

  return (
    <header className="border-border-subtle flex items-center justify-between border-b px-6 py-4">
      <h1 className="text-content text-lg font-semibold">Hydra UI Demo</h1>
      <div className="flex items-center gap-4">
        <span className="text-content-muted text-sm">
          {user?.id} · {user?.roles.join(", ")}
        </span>
        <ThemeToggle />
        <button
          onClick={() => void logout()}
          disabled={isPending}
          className="text-content-muted hover:text-content text-sm underline"
        >
          Sign out
        </button>
      </div>
    </header>
  );
}

export function App() {
  return (
    <HydraProvider apiBaseUrl={AUTH_BASE_URL} ordersBaseUrl={ORDERS_BASE_URL} tenantId={TENANT_ID}>
      <SessionGate
        fallback={
          <div className="relative flex min-h-screen items-center justify-center">
            <div className="absolute top-6 right-6">
              <ThemeToggle />
            </div>
            <LoginForm />
          </div>
        }
        pending={
          <div className="flex min-h-screen items-center justify-center">
            <p className="text-content-muted text-sm">Restoring your session…</p>
          </div>
        }
      >
        <Header />
        <main className="p-6">
          <OrderList />
        </main>
      </SessionGate>
    </HydraProvider>
  );
}
