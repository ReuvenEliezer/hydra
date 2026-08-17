import { forwardRef, type ButtonHTMLAttributes } from "react";
import { Loader2 } from "lucide-react";
import { cn } from "../../lib/cn";

export type ButtonVariant = "primary" | "secondary" | "danger" | "ghost";
export type ButtonSize = "sm" | "md";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** Disables the button and marks it busy for assistive tech. */
  isPending?: boolean;
}

const VARIANTS: Record<ButtonVariant, string> = {
  primary: "bg-brand text-brand-content shadow-raised hover:bg-brand-hover",
  secondary:
    "bg-surface text-content border border-border-strong shadow-raised hover:bg-surface-muted",
  danger: "bg-danger text-brand-content shadow-raised hover:opacity-90",
  ghost: "bg-transparent text-content hover:bg-surface-muted",
};

/**
 * Busy is NOT disabled-looking. Both states set the `disabled` attribute (unchanged
 * behaviour), so a `disabled:` utility would style them identically — which is the bug
 * this splits apart: previously both rendered at 50% opacity and a user could not tell
 * "you may not press this" from "your press is being handled".
 */
const BUSY: Record<ButtonVariant, string> = {
  primary: "bg-brand-hover text-brand-content shadow-none",
  secondary: "bg-surface-muted text-content border border-border-strong shadow-none",
  danger: "bg-danger text-brand-content opacity-90 shadow-none",
  ghost: "bg-surface-muted text-content",
};

/** Inert: recedes, loses the accent and the elevation entirely. */
const DISABLED =
  "bg-surface-muted text-content-muted border border-border-subtle shadow-none cursor-not-allowed";

const SIZES: Record<ButtonSize, string> = {
  sm: "h-9 px-3.5 text-sm",
  md: "h-11 px-5 text-sm",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { className, variant = "primary", size = "md", isPending = false, disabled, children, ...props },
  ref,
) {
  const isInert = disabled === true && !isPending;

  return (
    <button
      ref={ref}
      type={props.type ?? "button"}
      disabled={disabled === true || isPending}
      aria-busy={isPending || undefined}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-(--radius-control) font-semibold",
        "transition-[background-color,box-shadow,border-color,color]",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand",
        // Movement is opt-in so a reduced-motion user gets the colour change without the
        // press animation, rather than nothing at all.
        "motion-safe:active:translate-y-px motion-safe:transition-transform",
        isInert ? DISABLED : isPending ? BUSY[variant] : VARIANTS[variant],
        SIZES[size],
        className,
      )}
      {...props}
    >
      {isPending && (
        // Not gated on motion-safe: reduced motion stops the spin, it must not remove
        // the only signal that work is in flight.
        <Loader2 aria-hidden="true" className="size-4 shrink-0 motion-safe:animate-spin" />
      )}
      {children}
    </button>
  );
});
