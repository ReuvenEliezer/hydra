import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

/**
 * Dev server for `demo/` — a minimal standalone app consuming the package straight from
 * `src/` (no build step). Separate from `vite.config.ts`, which is library-build-only
 * and has no `index.html` to serve.
 */
export default defineConfig({
  root: resolve(__dirname, "demo"),
  envDir: __dirname,
  plugins: [react(), tailwindcss()],
  server: { port: 5173 },
});
