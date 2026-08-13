import type { HTMLAttributes, ReactNode } from "react";
import { cn } from "../../lib/cn";

export interface CardProps extends HTMLAttributes<HTMLDivElement> {
  title?: ReactNode;
  description?: ReactNode;
  footer?: ReactNode;
}

export function Card({
  className,
  title,
  description,
  footer,
  children,
  ...props
}: CardProps) {
  return (
    <div
      className={cn(
        "bg-surface border-border-subtle flex flex-col gap-4 rounded-xl border p-6",
        className,
      )}
      {...props}
    >
      {(title !== undefined || description !== undefined) && (
        <div className="flex flex-col gap-1">
          {title !== undefined && (
            <h2 className="text-content text-base font-semibold">{title}</h2>
          )}
          {description !== undefined && (
            <p className="text-content-muted text-sm">{description}</p>
          )}
        </div>
      )}
      {children}
      {footer !== undefined && (
        <div className="border-border-subtle flex justify-end gap-2 border-t pt-4">{footer}</div>
      )}
    </div>
  );
}
