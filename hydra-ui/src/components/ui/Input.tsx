import { forwardRef, useId, type InputHTMLAttributes } from "react";
import { AlertCircle } from "lucide-react";
import { cn } from "../../lib/cn";

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
  /** Field-level validation message; wires up aria-invalid/aria-describedby when set. */
  error?: string | null;
  hint?: string;
}

export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { className, label, error = null, hint, id, ...props },
  ref,
) {
  const generatedId = useId();
  const inputId = id ?? generatedId;
  const errorId = `${inputId}-error`;
  const hintId = `${inputId}-hint`;
  const describedBy = [error !== null ? errorId : null, hint !== undefined ? hintId : null]
    .filter((value): value is string => value !== null)
    .join(" ");

  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={inputId} className="text-content text-sm font-semibold">
        {label}
      </label>
      <input
        ref={ref}
        id={inputId}
        aria-invalid={error !== null || undefined}
        aria-describedby={describedBy.length > 0 ? describedBy : undefined}
        className={cn(
          // A recessed fill rather than a plain outline: the field reads as somewhere to
          // put something, which a 1px box on the same ground does not.
          "bg-surface-muted text-content border-border-strong h-11 rounded-(--radius-control)",
          "border px-3.5 text-sm shadow-[inset_0_1px_2px_oklch(0%_0_0/0.05)]",
          "placeholder:text-content-muted transition-[background-color,border-color,box-shadow]",
          "focus-visible:bg-surface focus-visible:border-brand focus-visible:outline-2",
          "focus-visible:outline-offset-0 focus-visible:outline-brand",
          "disabled:cursor-not-allowed disabled:opacity-60",
          error !== null && "border-danger bg-danger-surface",
          className,
        )}
        {...props}
      />
      {hint !== undefined && (
        <p id={hintId} className="text-content-muted text-xs">
          {hint}
        </p>
      )}
      {error !== null && (
        // The icon means the error is not signalled by colour alone.
        <p id={errorId} className="text-danger flex items-center gap-1.5 text-xs font-medium">
          <AlertCircle aria-hidden="true" className="size-3.5 shrink-0" />
          {error}
        </p>
      )}
    </div>
  );
});
