import { useState, type ReactNode } from "react";
import { AlertCircle } from "lucide-react";
import { useOrders } from "../../hooks/useOrders";
import { cn } from "../../lib/cn";
import { ORDER_STATUSES, type Order, type OrderStatus } from "../../types/order";
import { Button } from "../ui/Button";
import { Select, type SelectOption } from "../ui/Select";
import { Table, type TableColumn } from "../ui/Table";
import { ORDER_STATUS_LABELS, OrderStatusBadge } from "./OrderStatusBadge";

const ALL = "__all__";

const FILTER_OPTIONS: SelectOption[] = [
  { value: ALL, label: "All statuses" },
  ...ORDER_STATUSES.map((status) => ({ value: status, label: ORDER_STATUS_LABELS[status] })),
];

export interface OrderListProps {
  className?: string;
  onSelectOrder?: (order: Order) => void;
  /** Rendered in each row, e.g. an `OrderStatusControl` or `CancelOrderButton`. */
  rowActions?: (order: Order) => ReactNode;
  pageSize?: number;
}

/**
 * Newest-first ordering is the hook's responsibility (`sort=createdAt,desc`), not this
 * component's — see `useOrders` for why the backend default cannot be relied on.
 */
export function OrderList({ className, onSelectOrder, rowActions, pageSize = 20 }: OrderListProps) {
  const [statusFilter, setStatusFilter] = useState<string>(ALL);
  const filters = statusFilter === ALL ? { size: pageSize } : { status: statusFilter as OrderStatus, size: pageSize };
  const { orders, page, isLoading, error, loadPage } = useOrders(filters);

  const columns: TableColumn<Order>[] = [
    {
      key: "orderNumber",
      header: "Order",
      render: (order) => <span className="font-semibold">{order.orderNumber}</span>,
    },
    {
      key: "totalAmount",
      header: "Total",
      className: "text-right tabular-nums",
      render: (order) => order.totalAmount,
    },
    {
      key: "status",
      header: "Status",
      render: (order) => <OrderStatusBadge status={order.status} />,
    },
    { key: "createdAt", header: "Created", render: (order) => order.createdAt.replace("T", " ") },
  ];

  if (rowActions !== undefined) {
    columns.push({
      key: "actions",
      header: "",
      className: "text-right",
      render: (order) => <div className="flex justify-end gap-2">{rowActions(order)}</div>,
    });
  }

  const isFirstPage = page.number <= 0;
  const isLastPage = page.number >= page.totalPages - 1;

  return (
    <div className={cn("flex flex-col gap-5", className)}>
      <Select
        label="Filter by status"
        value={statusFilter}
        onValueChange={setStatusFilter}
        options={FILTER_OPTIONS}
        className="w-56"
      />

      {error !== null && (
        <p
          role="alert"
          className="bg-danger-surface text-danger border-danger/30 flex items-start gap-2 rounded-(--radius-control) border px-3.5 py-3 text-sm font-medium"
        >
          <AlertCircle aria-hidden="true" className="mt-px size-4 shrink-0" />
          {error.message}
        </p>
      )}

      <Table
        caption="Orders"
        columns={columns}
        rows={orders}
        rowKey={(order) => order.id}
        emptyMessage={isLoading ? "Loading orders…" : "No orders match this filter."}
        onRowClick={onSelectOrder}
      />

      {page.totalPages > 1 && (
        <div className="flex items-center justify-between text-sm">
          <span className="text-content-muted">
            Page {page.number + 1} of {page.totalPages} · {page.totalElements} orders
          </span>
          <div className="flex gap-2">
            <Button
              variant="secondary"
              size="sm"
              disabled={isFirstPage || isLoading}
              onClick={() => loadPage(page.number - 1)}
            >
              Previous
            </Button>
            <Button
              variant="secondary"
              size="sm"
              disabled={isLastPage || isLoading}
              onClick={() => loadPage(page.number + 1)}
            >
              Next
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
