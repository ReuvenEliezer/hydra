import type { Meta, StoryObj } from "@storybook/react";
import { LoginForm } from "../src/components/hydra/LoginForm";
import { SessionGate } from "../src/components/hydra/SessionGate";
import { useSession } from "../src/hooks/useSession";
import { withHydra } from "./hydra-decorator";

const meta: Meta<typeof LoginForm> = {
  title: "Hydra/LoginForm",
  component: LoginForm,
  parameters: { layout: "centered" },
};

export default meta;
type Story = StoryObj<typeof LoginForm>;

export const Default: Story = {
  render: (args) => withHydra(<LoginForm {...args} />),
};

function SessionInspector() {
  const { status, user } = useSession();
  return (
    <dl className="text-content bg-surface-muted rounded-(--radius-control) p-4 text-sm">
      <div className="flex gap-2">
        <dt className="font-medium">Status</dt>
        <dd data-testid="status">{status}</dd>
      </div>
      <div className="flex gap-2">
        <dt className="font-medium">User</dt>
        <dd>{user?.id ?? "—"}</dd>
      </div>
      <div className="flex gap-2">
        <dt className="font-medium">Roles</dt>
        <dd>{user?.roles.join(", ") || "—"}</dd>
      </div>
    </dl>
  );
}

/**
 * The scenario quickstart.md §2 walks through, in one place:
 *
 *  1. Sign in — watch `POST /api/v1/auth/login` and the `refresh_token` cookie appear
 *     (HttpOnly, SameSite=Strict, path /api/v1/auth) in devtools → Application.
 *  2. RELOAD THE PAGE — the status below returns to `authenticated` on its own, driven
 *     by a single `POST /api/v1/auth/refresh` at mount. Nothing was persisted; the
 *     cookie did all of it.
 *  3. Wait past the access token's validity (drop `jwt.expiration-duration` locally to
 *     make this quick), then press Reload orders. Exactly ONE refresh call appears in
 *     the network tab no matter how many requests were waiting on it.
 */
export const SignInAndSilentRenewal: Story = {
  render: () =>
    withHydra(
      <div className="flex w-80 flex-col gap-4">
        <SessionInspector />
        <SessionGate
          fallback={<LoginForm description="Sign in, then reload the page." />}
          pending={<p className="text-content-muted text-sm">Restoring your session…</p>}
        >
          <p className="text-content text-sm">
            Signed in. Reload the page — you should stay signed in.
          </p>
        </SessionGate>
      </div>,
    ),
};
