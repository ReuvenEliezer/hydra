import type { ReactNode } from "react";
import { Inbox } from "lucide-react";
import { cn } from "../../lib/cn";

export interface TableColumn<T> {
  key: string;
  header: ReactNode;
  render: (row: T) => ReactNode;
  className?: string;
}

export interface TableProps<T> {
  caption: string;
  columns: readonly TableColumn<T>[];
  rows: readonly T[];
  rowKey: (row: T) => string;
  emptyMessage?: ReactNode;
  onRowClick?: (row: T) => void;
  className?: string;
}

export function Table<T>({
  caption,
  columns,
  rows,
  rowKey,
  emptyMessage = "Nothing to show yet.",
  onRowClick,
  className,
}: TableProps<T>) {
  return (
    <div
      className={cn(
        "bg-surface border-border-subtle shadow-card overflow-x-auto rounded-(--radius-card) border",
        className,
      )}
    >
      <table className="w-full border-collapse text-left text-sm">
        <caption className="sr-only">{caption}</caption>
        <thead>
          <tr className="border-border-subtle border-b">
            {columns.map((column) => (
              <th
                key={column.key}
                scope="col"
                className={cn(
                  "text-content-muted px-5 py-3.5 text-xs font-semibold tracking-wide uppercase",
                  column.className,
                )}
              >
                {column.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={columns.length} className="px-5 py-14 text-center">
                <span className="bg-surface-muted text-content-muted mx-auto mb-3 flex size-11 items-center justify-center rounded-(--radius-control)">
                  <Inbox aria-hidden="true" className="size-5" />
                </span>
                <span className="text-content block text-sm font-semibold">{emptyMessage}</span>
              </td>
            </tr>
          ) : (
            rows.map((row) => (
              <tr
                key={rowKey(row)}
                onClick={onRowClick === undefined ? undefined : () => onRowClick(row)}
                className={cn(
                  "border-border-subtle text-content border-t transition-colors",
                  onRowClick !== undefined && "hover:bg-surface-muted cursor-pointer",
                )}
              >
                {columns.map((column) => (
                  <td key={column.key} className={cn("px-5 py-3.5", column.className)}>
                    {column.render(row)}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
