import { useState, type FormEvent } from "react";
import { AlertCircle } from "lucide-react";
import { useCreateOrder } from "../../hooks/useCreateOrder";
import { cn } from "../../lib/cn";
import type { Order } from "../../types/order";
import { Button } from "../ui/Button";
import { Card } from "../ui/Card";
import { Input } from "../ui/Input";

export interface CreateOrderFormProps {
  className?: string;
  onCreated?: (order: Order) => void;
}

export function CreateOrderForm({ className, onCreated }: CreateOrderFormProps) {
  const { createOrder, isPending, error, fieldErrors } = useCreateOrder();
  const [orderNumber, setOrderNumber] = useState("");
  const [totalAmount, setTotalAmount] = useState("");

  async function handleSubmit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    try {
      const order = await createOrder({ orderNumber, totalAmount });
      setOrderNumber("");
      setTotalAmount("");
      onCreated?.(order);
    } catch {
      // Rendered from the hook's `error`/`fieldErrors` below.
    }
  }

  // A duplicate order number is a tenant-scoped uniqueness check only the server can
  // make, so it arrives as a 422 rather than an inline validation error. Showing it as
  // its own message beats folding it into a generic failure (FR-023).
  const showsServerError = error !== null && error.code !== "validation_error";

  return (
    <Card title="New order" className={cn("w-full max-w-md", className)}>
      <form className="flex flex-col gap-5" onSubmit={handleSubmit} noValidate>
        <Input
          label="Order number"
          name="orderNumber"
          value={orderNumber}
          onChange={(event) => setOrderNumber(event.target.value)}
          error={fieldErrors.orderNumber ?? null}
          disabled={isPending}
        />
        <Input
          label="Total amount"
          name="totalAmount"
          inputMode="decimal"
          placeholder="0.00"
          value={totalAmount}
          onChange={(event) => setTotalAmount(event.target.value)}
          error={fieldErrors.totalAmount ?? null}
          disabled={isPending}
        />

        {showsServerError && (
          <p
            role="alert"
            data-error-code={error.code}
            className="bg-danger-surface text-danger border-danger/30 flex items-start gap-2 rounded-(--radius-control) border px-3.5 py-3 text-sm font-medium"
          >
            <AlertCircle aria-hidden="true" className="mt-px size-4 shrink-0" />
            {error.message}
          </p>
        )}

        <Button type="submit" isPending={isPending}>
          {isPending ? "Creating…" : "Create order"}
        </Button>
      </form>
    </Card>
  );
}
