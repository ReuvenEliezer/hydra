import { builtinEnvironments, type Environment } from "vitest/environments";

/**
 * jsdom, with Node's `AbortController`/`AbortSignal` put back.
 *
 * Why this exists
 * ---------------
 * jsdom installs its own `AbortController`/`AbortSignal` over the test global, but jsdom
 * implements no `fetch` — so `globalThis.fetch` stays Node's undici. undici validates
 * `RequestInit.signal` against the `AbortSignal` *it* captured when its module was
 * evaluated, which is Node's. A signal produced by jsdom's `AbortController` therefore
 * fails that check and every request rejects with:
 *
 *   TypeError: RequestInit: Expected signal ("AbortSignal {}") to be an instance of AbortSignal
 *
 * The failure is invisible from inside a test: `signal instanceof AbortSignal` is `true`
 * there, because both sides of that comparison are jsdom's. Only undici's internal
 * reference disagrees, which is why this looked like an msw bug and is not one —
 * upgrading `@mswjs/interceptors` 0.41.9 -> 0.42.3 made it strictly worse
 * (54 -> 59 failures). msw is merely the first code to construct a `Request`.
 *
 * Production code is correct and unchanged: `HydraProvider`, `useOrders`, `useOrder`, and
 * `session-manager` all create a plain `new AbortController()`, which in a real browser
 * is the same realm as `fetch`. It is only this test environment that splits them.
 *
 * The two constructors below are captured at module scope, which is evaluated in the Node
 * realm *before* `setup()` runs and jsdom overwrites the globals. That ordering is the
 * whole mechanism — do not move them inside `setup()`.
 */
const NodeAbortController = globalThis.AbortController;
const NodeAbortSignal = globalThis.AbortSignal;

const environment: Environment = {
  name: "jsdom-node-abort",
  transformMode: "web",
  async setup(global, options) {
    const { teardown } = await builtinEnvironments.jsdom.setup(global, options);

    Object.defineProperty(global, "AbortController", {
      value: NodeAbortController,
      configurable: true,
      writable: true,
    });
    Object.defineProperty(global, "AbortSignal", {
      value: NodeAbortSignal,
      configurable: true,
      writable: true,
    });

    return { teardown };
  },
};

export default environment;
