import * as RadixDialog from "@radix-ui/react-dialog";
import type { ReactNode } from "react";
import { cn } from "../../lib/cn";

/**
 * Radix rather than a hand-rolled modal: focus trapping, focus restore, Escape handling
 * and the `aria-modal` wiring are the parts that are easy to omit and impossible to
 * notice without a screen reader. `Description` is required by Radix for labelling, so
 * it is a required prop here rather than a silent runtime warning.
 */
export interface DialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description: string;
  children?: ReactNode;
  footer?: ReactNode;
  className?: string;
}

export function Dialog({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
  className,
}: DialogProps) {
  return (
    <RadixDialog.Root open={open} onOpenChange={onOpenChange}>
      <RadixDialog.Portal>
        <RadixDialog.Overlay className="fixed inset-0 bg-black/50 backdrop-blur-[2px]" />
        <RadixDialog.Content
          className={cn(
            // `surface-raised` is what separates the dialog from the page in dark mode;
            // the shadow does that job only in light mode.
            "bg-surface-raised border-border-subtle shadow-overlay fixed top-1/2 left-1/2",
            "w-[min(30rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2",
            "rounded-(--radius-card) border p-7",
            "flex flex-col gap-5",
            "motion-safe:data-[state=open]:animate-pop-in",
            className,
          )}
        >
          <div className="flex flex-col gap-1.5">
            <RadixDialog.Title className="text-content text-lg font-semibold tracking-tight">
              {title}
            </RadixDialog.Title>
            <RadixDialog.Description className="text-content-muted text-sm">
              {description}
            </RadixDialog.Description>
          </div>
          {children}
          {footer !== undefined && <div className="flex justify-end gap-2">{footer}</div>}
        </RadixDialog.Content>
      </RadixDialog.Portal>
    </RadixDialog.Root>
  );
}

export const DialogClose = RadixDialog.Close;
