import { resolve } from "node:path";
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

/**
 * Kept separate from vite.config.ts so the library build never has to load the test
 * setup (MSW, jsdom) and the test run never has to reason about library-mode output.
 */
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@": resolve(__dirname, "src"),
      "@components": resolve(__dirname, "src/components"),
      "@hooks": resolve(__dirname, "src/hooks"),
      "@lib": resolve(__dirname, "src/lib"),
      "@styles": resolve(__dirname, "src/styles"),
      "@hydra-types": resolve(__dirname, "src/types"),
    },
  },
  test: {
    globals: true,
    environment: "jsdom",
    setupFiles: ["./tests/setup.ts"],
    include: ["tests/**/*.test.{ts,tsx}"],
    restoreMocks: true,
  },
});
