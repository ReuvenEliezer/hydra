import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";

export default tseslint.config(
  {
    ignores: ["dist", "storybook-static", "node_modules", "coverage"],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["**/*.{ts,tsx}"],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.browser,
    },
    plugins: {
      "react-hooks": reactHooks,
      "react-refresh": reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
      // The refresh token must never be read from JS (FR-006). These are the two APIs
      // that could do it, so they are banned outright rather than reviewed case by case.
      "no-restricted-globals": [
        "error",
        { name: "localStorage", message: "Tokens must never be persisted (FR-006)." },
        { name: "sessionStorage", message: "Tokens must never be persisted (FR-006)." },
      ],
      "no-restricted-properties": [
        "error",
        {
          object: "document",
          property: "cookie",
          message: "The refresh token is httpOnly by design and must never be read from JS (FR-006).",
        },
      ],
    },
  },
  {
    files: ["tests/**/*.{ts,tsx}", "stories/**/*.{ts,tsx}", "*.config.{ts,js}"],
    languageOptions: {
      globals: { ...globals.browser, ...globals.node },
    },
    rules: {
      "react-refresh/only-export-components": "off",
    },
  },
  {
    // Build-time tooling: runs under Node, never shipped to a browser.
    files: ["scripts/**/*.{mjs,js}"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: globals.node,
    },
  },
);
