import { useCallback, useState } from "react";
import { useOrdersClient } from "../components/HydraProvider";
import { ApiError } from "../types/errors";
import { normalizeOrder, type CreateOrderInput, type Order } from "../types/order";

export interface UseCreateOrderResult {
  createOrder: (input: CreateOrderInput) => Promise<Order>;
  isPending: boolean;
  error: ApiError | null;
  /** Per-field messages from the client-side check, keyed by input name. */
  fieldErrors: CreateOrderFieldErrors;
  reset: () => void;
}

export interface CreateOrderFieldErrors {
  orderNumber?: string;
  totalAmount?: string;
}

/**
 * Client-side mirror of `CreateOrderRequest`'s constraints: `@NotBlank` on
 * `orderNumber`, `@NotNull @DecimalMin("0.01")` on `totalAmount`.
 *
 * `totalAmount` stays a string all the way to the wire — it is a `BigDecimal`
 * server-side, and routing money through a JS `number` to validate it is how you end up
 * submitting 0.30000000000000004.
 */
export function validateCreateOrder(input: CreateOrderInput): CreateOrderFieldErrors {
  const errors: CreateOrderFieldErrors = {};

  if (input.orderNumber.trim().length === 0) {
    errors.orderNumber = "Order number is required";
  }

  const amount = input.totalAmount.trim();
  if (amount.length === 0) {
    errors.totalAmount = "Total amount is required";
  } else if (!/^\d+(\.\d+)?$/.test(amount)) {
    errors.totalAmount = "Total amount must be a number";
  } else if (Number(amount) < 0.01) {
    errors.totalAmount = "Total amount must be greater than 0";
  }

  return errors;
}

export function hasCreateOrderErrors(errors: CreateOrderFieldErrors): boolean {
  return errors.orderNumber !== undefined || errors.totalAmount !== undefined;
}

/**
 * Wraps `POST /api/orders`.
 *
 * Invalid input never reaches the network (FR-011). A duplicate order number does — it
 * is a tenant-scoped uniqueness check the client cannot perform — and comes back as a
 * 422 `business_rule_violation`, kept distinct from a validation failure so the form can
 * say "that order number is already taken" rather than "invalid input" (FR-023).
 */
export function useCreateOrder(): UseCreateOrderResult {
  const client = useOrdersClient();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);
  const [fieldErrors, setFieldErrors] = useState<CreateOrderFieldErrors>({});

  const createOrder = useCallback(
    async (input: CreateOrderInput): Promise<Order> => {
      const validation = validateCreateOrder(input);
      setFieldErrors(validation);
      if (hasCreateOrderErrors(validation)) {
        const validationError = new ApiError({
          code: "validation_error",
          message: validation.orderNumber ?? validation.totalAmount ?? "Invalid order",
          status: 0,
        });
        setError(validationError);
        throw validationError;
      }

      setIsPending(true);
      setError(null);
      try {
        const body = await client.request<unknown>("/api/orders", {
          method: "POST",
          body: { orderNumber: input.orderNumber.trim(), totalAmount: input.totalAmount.trim() },
        });
        return normalizeOrder(body);
      } catch (caught) {
        if (caught instanceof ApiError) setError(caught);
        throw caught;
      } finally {
        setIsPending(false);
      }
    },
    [client],
  );

  const reset = useCallback(() => {
    setError(null);
    setFieldErrors({});
  }, []);

  return { createOrder, isPending, error, fieldErrors, reset };
}
