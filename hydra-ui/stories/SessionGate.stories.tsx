import type { Meta, StoryObj } from "@storybook/react";
import { LoginForm } from "../src/components/hydra/LoginForm";
import { SessionGate } from "../src/components/hydra/SessionGate";
import { Button } from "../src/components/ui/Button";
import { useLogout } from "../src/hooks/useLogout";
import { useSession } from "../src/hooks/useSession";
import { withHydra } from "./hydra-decorator";

const meta: Meta<typeof SessionGate> = {
  title: "Hydra/SessionGate",
  parameters: { layout: "centered" },
};

export default meta;
type Story = StoryObj<typeof SessionGate>;

function SignOutControl() {
  const { logout, isPending } = useLogout();
  const { user } = useSession();

  return (
    <div className="flex items-center gap-3">
      <span className="text-content-muted text-sm">{user?.id ?? "—"}</span>
      <Button variant="secondary" size="sm" isPending={isPending} onClick={() => void logout()}>
        Sign out
      </Button>
    </div>
  );
}

/**
 * quickstart.md §3. Sign in, then sign out and watch two things in devtools:
 *
 *  - the `refresh_token` cookie is cleared (`Max-Age=0`), and
 *  - NO further `/api/v1/auth/refresh` call fires afterwards, even if one was already
 *    in flight when you clicked. Local state is cleared before the logout request is
 *    even sent, which is what makes that hold.
 */
export const WithSignOut: Story = {
  render: () =>
    withHydra(
      <div className="flex w-80 flex-col gap-4">
        <SessionGate
          fallback={<LoginForm description="Sign in to see the sign-out control." />}
          pending={<p className="text-content-muted text-sm">Restoring your session…</p>}
        >
          <div className="flex flex-col gap-4">
            <p className="text-content text-sm">You are signed in.</p>
            <SignOutControl />
          </div>
        </SessionGate>
      </div>,
    ),
};
