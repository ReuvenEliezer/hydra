import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/**
 * Conditional classes via clsx, then conflict resolution via tailwind-merge, so a
 * consumer's `className="px-8"` actually beats a component's default `px-4` instead of
 * both landing in the class list and letting stylesheet order decide.
 */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}
