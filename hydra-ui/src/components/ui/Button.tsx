import { forwardRef, type ButtonHTMLAttributes } from "react";
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
  primary: "bg-brand text-brand-content hover:bg-brand-hover",
  secondary: "bg-surface-muted text-content border border-border-subtle hover:bg-surface",
  danger: "bg-danger text-brand-content hover:opacity-90",
  ghost: "bg-transparent text-content hover:bg-surface-muted",
};

const SIZES: Record<ButtonSize, string> = {
  sm: "h-8 px-3 text-sm",
  md: "h-10 px-4 text-sm",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { className, variant = "primary", size = "md", isPending = false, disabled, ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      type={props.type ?? "button"}
      disabled={disabled === true || isPending}
      aria-busy={isPending || undefined}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-(--radius-control) font-medium",
        "transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand",
        "disabled:cursor-not-allowed disabled:opacity-50",
        VARIANTS[variant],
        SIZES[size],
        className,
      )}
      {...props}
    />
  );
});
