import type { Meta, StoryObj } from "@storybook/react";
import { LoginForm } from "../src/components/hydra/LoginForm";
import { RegisterAdminForm } from "../src/components/hydra/RegisterAdminForm";
import { RegisterUserForm } from "../src/components/hydra/RegisterUserForm";
import { SessionGate } from "../src/components/hydra/SessionGate";
import { useSession } from "../src/hooks/useSession";
import { STORY_TENANT_ID, withHydra } from "./hydra-decorator";

const meta: Meta = {
  title: "Hydra/Provisioning",
  parameters: { layout: "centered" },
};

export default meta;
type Story = StoryObj;

function CurrentRoles() {
  const { user } = useSession();
  return (
    <p className="text-content-muted text-sm">
      Signed in with: {user?.roles.join(", ") || "—"}
    </p>
  );
}

/**
 * quickstart.md §5. Both forms are rendered unconditionally here — what changes is which
 * of them appears, and that is decided entirely by the session's roles:
 *
 *  - as `ROLE_ADMIN` you see only "Add a user";
 *  - as `ROLE_SUPER_ADMIN` you see both.
 *
 * Neither form is merely disabled for the wrong role; it is not mounted at all, so
 * there is no submit path to reach.
 */
export const BothForms: Story = {
  render: () =>
    withHydra(
      <SessionGate
        fallback={<LoginForm description="Sign in as an admin or super admin." />}
        pending={<p className="text-content-muted text-sm">Restoring your session…</p>}
      >
        <div className="flex flex-col gap-6">
          <CurrentRoles />
          <RegisterUserForm />
          <RegisterAdminForm defaultTenantId={STORY_TENANT_ID} />
        </div>
      </SessionGate>,
    ),
};
