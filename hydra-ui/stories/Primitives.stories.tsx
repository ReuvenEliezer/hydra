import type { Meta, StoryObj } from "@storybook/react";
import { useState } from "react";
import { Button } from "../src/components/ui/Button";
import { Card } from "../src/components/ui/Card";
import { Input } from "../src/components/ui/Input";
import { Select } from "../src/components/ui/Select";
import { Table } from "../src/components/ui/Table";
import { Dialog } from "../src/components/ui/Dialog";
import { OrderStatusBadge, ORDER_STATUS_LABELS } from "../src/components/hydra/OrderStatusBadge";
import { ORDER_STATUSES, type OrderStatus } from "../src/types/order";

/**
 * Every primitive, every variant, on one surface.
 *
 * This exists because the primitives previously had no story at all — they could not be
 * viewed or screenshotted, which made the before/after sign-off in SC-001 impossible to
 * actually perform. Needs no running backend: nothing here calls a hook.
 */
const meta: Meta = {
  title: "Design System/Primitives",
  parameters: { layout: "fullscreen" },
};
export default meta;
type Story = StoryObj;

type Row = { id: string; item: string; qty: number; status: OrderStatus };

const ROWS: Row[] = [
  { id: "1", item: "Blue widget", qty: 2, status: "PENDING" },
  { id: "2", item: "Red gadget", qty: 1, status: "SHIPPED" },
  { id: "3", item: "Green doohickey", qty: 7, status: "DELIVERED" },
  { id: "4", item: "Yellow thingamajig", qty: 3, status: "CANCELLED" },
];

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-4">
      <h3 className="text-content-muted text-xs font-semibold tracking-wider uppercase">
        {title}
      </h3>
      {children}
    </section>
  );
}

function Sink() {
  const [status, setStatus] = useState<OrderStatus | undefined>("PENDING");
  const [open, setOpen] = useState(false);

  return (
    <div className="bg-surface-muted min-h-screen p-8">
      <div className="mx-auto flex max-w-4xl flex-col gap-10">
        <header className="flex flex-col gap-1">
          <h2 className="text-content text-2xl font-semibold tracking-tight">Primitives</h2>
          <p className="text-content-muted text-sm">
            Toggle <code className="font-mono text-xs">data-theme</code> on
            <code className="font-mono text-xs"> &lt;html&gt;</code> between “light” and “dark”,
            and remove it entirely to check the system-preference path.
          </p>
        </header>

        <Section title="Buttons">
          <div className="flex flex-wrap items-center gap-3">
            <Button variant="primary">Primary</Button>
            <Button variant="secondary">Secondary</Button>
            <Button variant="danger">Danger</Button>
            <Button variant="ghost">Ghost</Button>
            <Button variant="primary" size="sm">
              Small
            </Button>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            {/* The pair that used to be indistinguishable: both set `disabled`, but
                inert recedes while busy keeps the accent and shows progress. */}
            <Button variant="primary" disabled>
              Disabled
            </Button>
            <Button variant="primary" isPending>
              Signing in…
            </Button>
            <Button variant="secondary" isPending>
              Saving…
            </Button>
            <Button variant="danger" isPending>
              Cancelling…
            </Button>
          </div>
        </Section>

        <Section title="Status badges">
          <div className="flex flex-wrap items-center gap-3">
            {ORDER_STATUSES.map((s) => (
              <OrderStatusBadge key={s} status={s} />
            ))}
          </div>
          <p className="text-content-muted text-xs">
            Each carries a glyph as well as a colour, so status survives greyscale and colour
            blindness.
          </p>
        </Section>

        <Section title="Inputs and select">
          <div className="grid gap-5 sm:grid-cols-2">
            <Input label="Username" placeholder="jane.doe" />
            <Input label="With hint" hint="Must be at least 8 characters." />
            <Input label="With error" error="This field is required." />
            <Input label="Disabled" disabled placeholder="Unavailable" />
            <Select
              label="Status"
              value={status}
              onValueChange={setStatus}
              options={ORDER_STATUSES.map((s) => ({ value: s, label: ORDER_STATUS_LABELS[s] }))}
            />
            <Select
              label="Disabled select"
              value={undefined}
              onValueChange={() => {}}
              options={[]}
              disabled
            />
          </div>
        </Section>

        <Section title="Card">
          <Card
            title="Order #1024"
            description="Placed 12 minutes ago by jane.doe"
            footer={
              <>
                <Button variant="ghost">Discard</Button>
                <Button variant="primary">Confirm</Button>
              </>
            }
          >
            <p className="text-content-muted text-sm">Card body content goes here.</p>
          </Card>
        </Section>

        <Section title="Table">
          <Table<Row>
            caption="Orders"
            rows={ROWS}
            rowKey={(r) => r.id}
            onRowClick={() => {}}
            columns={[
              {
                key: "item",
                header: "Item",
                render: (r) => <span className="font-semibold">{r.item}</span>,
              },
              { key: "qty", header: "Qty", className: "tabular-nums", render: (r) => r.qty },
              {
                key: "status",
                header: "Status",
                render: (r) => <OrderStatusBadge status={r.status} />,
              },
            ]}
          />
          <Table<Row>
            caption="Empty orders"
            rows={[]}
            rowKey={(r) => r.id}
            emptyMessage="No orders yet"
            columns={[{ key: "item", header: "Item", render: (r) => r.item }]}
          />
        </Section>

        <Section title="Dialog">
          <div>
            <Button onClick={() => setOpen(true)}>Open dialog</Button>
          </div>
          <Dialog
            open={open}
            onOpenChange={setOpen}
            title="Cancel this order?"
            description="The order is kept on record with a cancelled status. This can't be undone."
            footer={
              <>
                <Button variant="secondary" onClick={() => setOpen(false)}>
                  Keep order
                </Button>
                <Button variant="danger" onClick={() => setOpen(false)}>
                  Cancel order
                </Button>
              </>
            }
          />
        </Section>

        <Section title="Elevation">
          <div className="flex flex-wrap gap-5">
            {(
              [
                ["bg-surface shadow-raised", "Raised", "Controls at rest"],
                ["bg-surface shadow-card", "Card", "Panels and tables"],
                ["bg-surface-raised shadow-overlay", "Overlay", "Dialog, popover"],
              ] as const
            ).map(([cls, name, blurb]) => (
              <div
                key={name}
                className={`border-border-subtle flex h-24 w-56 flex-col justify-end rounded-(--radius-card) border p-4 ${cls}`}
              >
                <span className="text-content text-sm font-semibold">{name}</span>
                <span className="text-content-muted text-xs">{blurb}</span>
              </div>
            ))}
          </div>
          <p className="text-content-muted text-xs">
            Each level is a shadow <em>and</em> a surface. In dark mode the shadow is a dark halo
            on a dark ground and reads as almost nothing — the surface step is what actually
            carries the hierarchy, which is why the two are always applied together.
          </p>
        </Section>
      </div>
    </div>
  );
}

export const KitchenSink: Story = { render: () => <Sink /> };
