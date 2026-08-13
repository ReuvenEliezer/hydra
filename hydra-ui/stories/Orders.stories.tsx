import type { Meta, StoryObj } from "@storybook/react";
import { useState } from "react";
import { CancelOrderButton } from "../src/components/hydra/CancelOrderButton";
import { CreateOrderForm } from "../src/components/hydra/CreateOrderForm";
import { LoginForm } from "../src/components/hydra/LoginForm";
import { OrderDetail } from "../src/components/hydra/OrderDetail";
import { OrderList } from "../src/components/hydra/OrderList";
import { OrderStatusControl } from "../src/components/hydra/OrderStatusControl";
import { SessionGate } from "../src/components/hydra/SessionGate";
import type { Order } from "../src/types/order";
import { withHydra } from "./hydra-decorator";

const meta: Meta = {
  title: "Hydra/Orders",
  parameters: { layout: "fullscreen" },
};

export default meta;
type Story = StoryObj;

function OrdersWorkbench() {
  const [selected, setSelected] = useState<Order | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  function reload() {
    setReloadKey((key) => key + 1);
  }

  return (
    <div className="grid gap-6 p-6 lg:grid-cols-[2fr_1fr]">
      <div className="flex flex-col gap-6">
        <OrderList
          key={reloadKey}
          onSelectOrder={setSelected}
          rowActions={(order) => (
            // Both controls are wrapped in RequireRole("ROLE_ADMIN") internally, so a
            // standard user's rows render with an empty actions cell rather than
            // disabled buttons.
            <>
              <CancelOrderButton order={order} onCancelled={reload} />
            </>
          )}
        />
        {selected !== null && (
          <OrderDetail
            key={`${selected.id}-${reloadKey}`}
            orderId={selected.id}
            actions={
              <OrderStatusControl
                order={selected}
                onUpdated={(order) => {
                  setSelected(order);
                  reload();
                }}
              />
            }
          />
        )}
      </div>
      <CreateOrderForm onCreated={reload} />
    </div>
  );
}

/**
 * quickstart.md §4. Sign in as a `ROLE_USER` first: list, filter, create, and confirm
 * the status/cancel controls are absent. Then sign in as a `ROLE_ADMIN` and confirm they
 * appear — and that the status dropdown offers only the transitions the backend accepts
 * for that order's current status.
 */
export const Workbench: Story = {
  render: () =>
    withHydra(
      <SessionGate
        fallback={
          <div className="p-6">
            <LoginForm description="Sign in to manage orders." />
          </div>
        }
        pending={<p className="text-content-muted p-6 text-sm">Restoring your session…</p>}
      >
        <OrdersWorkbench />
      </SessionGate>,
    ),
};
