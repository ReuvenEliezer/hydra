import type { ReactNode } from "react";
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
    <div className={cn("border-border-subtle overflow-x-auto rounded-xl border", className)}>
      <table className="w-full border-collapse text-left text-sm">
        <caption className="sr-only">{caption}</caption>
        <thead className="bg-surface-muted">
          <tr>
            {columns.map((column) => (
              <th
                key={column.key}
                scope="col"
                className={cn("text-content-muted px-4 py-2.5 font-medium", column.className)}
              >
                {column.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td
                colSpan={columns.length}
                className="text-content-muted px-4 py-8 text-center"
              >
                {emptyMessage}
              </td>
            </tr>
          ) : (
            rows.map((row) => (
              <tr
                key={rowKey(row)}
                onClick={onRowClick === undefined ? undefined : () => onRowClick(row)}
                className={cn(
                  "border-border-subtle text-content border-t",
                  onRowClick !== undefined && "hover:bg-surface-muted cursor-pointer",
                )}
              >
                {columns.map((column) => (
                  <td key={column.key} className={cn("px-4 py-2.5", column.className)}>
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
