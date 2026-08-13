import "@testing-library/jest-dom/vitest";
import { afterAll, afterEach, beforeAll } from "vitest";
import { cleanup } from "@testing-library/react";
import { server } from "./mocks/server";

/**
 * MSW intercepts at the request level rather than stubbing `fetch`, so the code under
 * test exercises its real headers, `credentials: "include"`, and response parsing —
 * which is the whole point for the refresh flow (research.md §5).
 *
 * `onUnhandledRequest: "error"` is deliberate: a request the handlers don't cover is a
 * test bug (usually a wrong URL), and silently letting it through would make a
 * refresh-coalescing assertion pass for the wrong reason.
 */
beforeAll(() => server.listen({ onUnhandledRequest: "error" }));

/**
 * Radix's Dialog and Select drive themselves off Pointer Events and layout measurement,
 * neither of which jsdom implements. Without these shims the components throw on open,
 * which would make every role-gating assertion fail for a reason that has nothing to do
 * with roles.
 */
if (!("PointerEvent" in globalThis)) {
  globalThis.PointerEvent = globalThis.MouseEvent as unknown as typeof PointerEvent;
}
if (typeof Element !== "undefined") {
  Element.prototype.hasPointerCapture ??= () => false;
  Element.prototype.setPointerCapture ??= () => undefined;
  Element.prototype.releasePointerCapture ??= () => undefined;
  Element.prototype.scrollIntoView ??= () => undefined;
}
if (!("ResizeObserver" in globalThis)) {
  globalThis.ResizeObserver = class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  } as unknown as typeof ResizeObserver;
}

afterEach(() => {
  server.resetHandlers();
  cleanup();
});

afterAll(() => server.close());
