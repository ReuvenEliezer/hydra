import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import dts from "vite-plugin-dts";

/**
 * Library-mode build: ESM only (the package targets modern bundlers and declares
 * `"type": "module"`), with type declarations emitted alongside.
 *
 * React/react-dom are external so a consuming app never ends up with two React copies —
 * that would break hooks, including this package's own session context.
 */
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    dts({
      include: ["src"],
      exclude: ["src/**/*.test.ts", "src/**/*.test.tsx"],
      insertTypesEntry: true,
    }),
  ],
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
  build: {
    lib: {
      // Two entries: the API, and a CSS-only entry whose sole job is to make Vite emit
      // the compiled stylesheet as an asset. Keeping them separate is what lets
      // `src/index.ts` stay side-effect-free.
      entry: {
        index: resolve(__dirname, "src/index.ts"),
        styles: resolve(__dirname, "src/styles.ts"),
      },
      formats: ["es"],
      // File naming is governed by `output.entryFileNames` below, because
      // `preserveModules` emits one file per source module rather than one bundle.
    },
    rollupOptions: {
      external: ["react", "react-dom", "react/jsx-runtime"],
      output: {
        // Per-file chunks rather than one bundle: combined with `sideEffects`, this is
        // what lets a consumer importing only `useSession` avoid pulling in the order
        // components (plan.md Performance Goals).
        preserveModules: true,
        preserveModulesRoot: "src",
        entryFileNames: "[name].js",
        // Pinned, unhashed name so `package.json`'s "./styles.css" export can point at
        // a stable path. If this changes, that export must change with it.
        assetFileNames: "hydra-ui.[ext]",
        chunkFileNames: "[name].js",
      },
    },
    sourcemap: true,
    target: "es2022",
  },
});
