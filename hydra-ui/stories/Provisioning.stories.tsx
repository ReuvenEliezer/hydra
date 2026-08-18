import type { Meta, StoryObj } from "@storybook/react";
import { LoginForm } from "../src/components/hydra/LoginForm";
import { RegisterAdminForm } from "../src/components/hydra/RegisterAdminForm";
import { RegisterUserForm } from "../src/components/hydra/RegisterUserForm";
import { SessionGate } from "../src/components/hydra/SessionGate";
import { useSession } from "../src/hooks/useSession";
import { withHydra } from "./hydra-decorator";

/**
 * A fixture UUID for the story only. Unlike LoginForm, `RegisterAdminForm` legitimately
 * names a TARGET tenant by id — it is an authenticated super-admin surface whose caller
 * already works in tenant UUIDs — so this prop is deliberately untouched by the move to
 * address-based resolution. Replace it with a real tenant id when running the story.
 */
const TARGET_TENANT_ID = "9a0c6391-d84f-48d0-9867-30193fc8951c";

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
          <RegisterAdminForm defaultTenantId={TARGET_TENANT_ID} />
        </div>
      </SessionGate>,
    ),
};
