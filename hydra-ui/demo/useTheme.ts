import { useCallback, useEffect, useState } from "react";

type Theme = "light" | "dark";

const STORAGE_KEY = "hydra-demo-theme";

function systemPrefersDark(): boolean {
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

function readInitialTheme(): Theme {
  // FR-006 bans persisting TOKENS. This is a display preference under `hydra-demo-theme`, and
  // losing it on reload is the only thing at stake. The ban stays in force everywhere else in
  // demo/, including App.tsx where the session actually lives - hence a line-scoped exemption
  // rather than a demo/ entry in eslint.config.js.
  // eslint-disable-next-line no-restricted-globals
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored === "light" || stored === "dark") return stored;
  return systemPrefersDark() ? "dark" : "light";
}

/**
 * Manual light/dark toggle, layered on top of the CSS in `styles/index.css` which
 * already follows `prefers-color-scheme` on its own. Setting `data-theme` on <html>
 * overrides that — see the three-state comment there — so no OS setting is required to
 * see both palettes.
 */
export function useTheme(): { theme: Theme; toggle: () => void } {
  const [theme, setTheme] = useState<Theme>(readInitialTheme);

  useEffect(() => {
    document.documentElement.dataset["theme"] = theme;
    // Display preference, not a token - see readInitialTheme above.
    // eslint-disable-next-line no-restricted-globals
    localStorage.setItem(STORAGE_KEY, theme);
  }, [theme]);

  const toggle = useCallback(() => {
    setTheme((current) => (current === "dark" ? "light" : "dark"));
  }, []);

  return { theme, toggle };
}
