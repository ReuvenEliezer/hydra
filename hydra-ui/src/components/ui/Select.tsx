import * as RadixSelect from "@radix-ui/react-select";
import { Check, ChevronDown } from "lucide-react";
import { useId } from "react";
import { cn } from "../../lib/cn";

export interface SelectOption<T extends string = string> {
  value: T;
  label: string;
}

export interface SelectProps<T extends string = string> {
  label: string;
  value: T | undefined;
  onValueChange: (value: T) => void;
  options: readonly SelectOption<T>[];
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  /** Hides the visible label while keeping it available to assistive tech. */
  hideLabel?: boolean;
}

export function Select<T extends string = string>({
  label,
  value,
  onValueChange,
  options,
  placeholder = "Select…",
  disabled = false,
  className,
  hideLabel = false,
}: SelectProps<T>) {
  const labelId = useId();

  return (
    <div className="flex flex-col gap-1.5">
      <span
        id={labelId}
        className={cn("text-content text-sm font-medium", hideLabel && "sr-only")}
      >
        {label}
      </span>
      <RadixSelect.Root
        value={value}
        onValueChange={(next) => onValueChange(next as T)}
        disabled={disabled}
      >
        <RadixSelect.Trigger
          aria-labelledby={labelId}
          className={cn(
            "bg-surface text-content border-border-subtle inline-flex h-10 items-center justify-between gap-2",
            "rounded-(--radius-control) border px-3 text-sm",
            "focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-brand",
            "disabled:cursor-not-allowed disabled:opacity-50",
            className,
          )}
        >
          <RadixSelect.Value placeholder={placeholder} />
          <RadixSelect.Icon>
            <ChevronDown aria-hidden="true" className="size-4" />
          </RadixSelect.Icon>
        </RadixSelect.Trigger>
        <RadixSelect.Portal>
          <RadixSelect.Content
            position="popper"
            sideOffset={4}
            className="bg-surface border-border-subtle z-50 overflow-hidden rounded-(--radius-control) border shadow-lg"
          >
            <RadixSelect.Viewport className="p-1">
              {options.map((option) => (
                <RadixSelect.Item
                  key={option.value}
                  value={option.value}
                  className={cn(
                    "text-content flex cursor-default items-center gap-2 rounded px-2 py-1.5 text-sm",
                    "data-[highlighted]:bg-surface-muted data-[highlighted]:outline-none",
                  )}
                >
                  <RadixSelect.ItemIndicator>
                    <Check aria-hidden="true" className="size-4" />
                  </RadixSelect.ItemIndicator>
                  <RadixSelect.ItemText>{option.label}</RadixSelect.ItemText>
                </RadixSelect.Item>
              ))}
            </RadixSelect.Viewport>
          </RadixSelect.Content>
        </RadixSelect.Portal>
      </RadixSelect.Root>
    </div>
  );
}
