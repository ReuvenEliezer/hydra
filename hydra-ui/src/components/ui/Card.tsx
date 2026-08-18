import type { HTMLAttributes, ReactNode } from "react";
import { cn } from "../../lib/cn";

/**
 * `title` is omitted from the base attributes before being redeclared: on a DOM element
 * `title` is the tooltip string, and widening it to `ReactNode` is not a legal extension of
 * `HTMLAttributes` (TS2430). The card's title is a heading, not a tooltip, so the DOM meaning
 * is the one to drop — and dropping it also stops a `<Card title={<span/>}/>` from spreading
 * a React element onto the div's `title` attribute.
 */
export interface CardProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
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
        // Elevation, not just a hairline: a card has to sit above the page for the
        // hierarchy to read at all.
        "bg-surface border-border-subtle shadow-card flex flex-col gap-5 rounded-(--radius-card)",
        "border p-7",
        className,
      )}
      {...props}
    >
      {(title !== undefined || description !== undefined) && (
        <div className="flex flex-col gap-1.5">
          {title !== undefined && (
            <h2 className="text-content text-lg font-semibold tracking-tight">{title}</h2>
          )}
          {description !== undefined && (
            <p className="text-content-muted text-sm">{description}</p>
          )}
        </div>
      )}
      {children}
      {footer !== undefined && (
        <div className="border-border-subtle flex justify-end gap-2 border-t pt-5">{footer}</div>
      )}
    </div>
  );
}
