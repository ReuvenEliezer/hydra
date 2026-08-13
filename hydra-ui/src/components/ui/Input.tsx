import { forwardRef, useId, type InputHTMLAttributes } from "react";
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
      <label htmlFor={inputId} className="text-content text-sm font-medium">
        {label}
      </label>
      <input
        ref={ref}
        id={inputId}
        aria-invalid={error !== null || undefined}
        aria-describedby={describedBy.length > 0 ? describedBy : undefined}
        className={cn(
          "bg-surface text-content border-border-subtle h-10 rounded-(--radius-control) border px-3 text-sm",
          "focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-brand",
          "disabled:cursor-not-allowed disabled:opacity-50",
          error !== null && "border-danger",
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
        <p id={errorId} className="text-danger text-xs">
          {error}
        </p>
      )}
    </div>
  );
});
