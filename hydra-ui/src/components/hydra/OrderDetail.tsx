import type { ReactNode } from "react";
import { AlertCircle, Loader2 } from "lucide-react";
import { useOrder } from "../../hooks/useOrder";
import { cn } from "../../lib/cn";
import { Card } from "../ui/Card";
import { OrderStatusBadge } from "./OrderStatusBadge";

export interface OrderDetailProps {
  orderId: string;
  className?: string;
  /** Admin controls to render in the footer, e.g. status change / cancel. */
  actions?: ReactNode;
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <dt className="text-content-muted text-xs font-semibold tracking-wide uppercase">
        {label}
      </dt>
      <dd className="text-content text-sm font-medium">{children}</dd>
    </div>
  );
}

export function OrderDetail({ orderId, className, actions }: OrderDetailProps) {
  const { order, isLoading, error } = useOrder(orderId);

  if (isLoading) {
    return (
      <Card className={className}>
        <p className="text-content-muted flex items-center gap-2 text-sm">
          <Loader2 aria-hidden="true" className="size-4 motion-safe:animate-spin" />
          Loading order…
        </p>
      </Card>
    );
  }

  if (error !== null) {
    return (
      <Card className={cn("border-danger/30", className)}>
        <p
          role="alert"
          className="text-danger flex items-start gap-2 text-sm font-medium"
          data-error-code={error.code}
        >
          <AlertCircle aria-hidden="true" className="mt-px size-4 shrink-0" />
          {/* A tenant-scoped lookup means someone else's order reads as "not found"
              rather than "forbidden", which is exactly what the user should see. */}
          {error.code === "not_found" ? "That order doesn't exist." : error.message}
        </p>
      </Card>
    );
  }

  if (order === null) return null;

  return (
    <Card
      className={cn("gap-6", className)}
      title={`Order ${order.orderNumber}`}
      footer={actions}
    >
      <dl className="grid grid-cols-2 gap-4">
        <Field label="Status">
          <OrderStatusBadge status={order.status} />
        </Field>
        <Field label="Total">
          <span className="tabular-nums">{order.totalAmount}</span>
        </Field>
        <Field label="Created">{order.createdAt.replace("T", " ")}</Field>
        <Field label="Last updated">{order.updatedAt.replace("T", " ")}</Field>
        <Field label="Order ID">
          <span className="font-mono text-xs">{order.id}</span>
        </Field>
        <Field label="Created by">
          <span className="font-mono text-xs">{order.createdBy}</span>
        </Field>
      </dl>
    </Card>
  );
}
