# The hostile edge

Two deliberately wrong gateway configurations, applied by
`make test-hostile-edge`.

## Why this exists

A conformance suite that only ever meets a **correct** edge cannot distinguish
two very different situations:

- the edge is transparent, or
- the assertions have stopped working.

The pass alone proves nothing (FR-042). So the same unmodified suite is run
against a gateway that is wrong on purpose, and it must **fail, naming the
violated clause**.

## What each one does

| File | Violates | The mistake it makes |
|---|---|---|
| `host-rewrite.yaml` | Clause 1 | Rewrites `Host` to the backend service name |
| `gateway-cors.yaml` | Clause 2 | Makes the gateway emit its own CORS headers |

Both are mistakes a **real gateway plausibly makes by accident**. That is the
selection criterion — an absurd configuration would prove nothing about whether
the suite catches realistic failures.

### `host-rewrite.yaml`

`proxy_set_header Host $proxy_host` is the default in a great deal of nginx
configuration in the world, and several ingress controllers do the equivalent.
It is normally harmless.

Against Hydra it is a **total outage**. Tenant identity comes from `Host` and
from nothing else, so every tenant resolves to `unknown` at once. There is no
partial failure mode and no degraded service — the whole product stops working
for everyone simultaneously.

### `gateway-cors.yaml`

Many gateways ship CORS handling enabled, and a gateway adding CORS for a
backend that has none is reasonable.

Hydra's `browser-edge-starter` already emits `Access-Control-Allow-Origin`,
echoing the single matching origin — which is what keeps `allowCredentials(true)`
legal for the refresh-cookie flow. With the gateway emitting too, the browser
gets **two** `Access-Control-Allow-Origin` headers and rejects the response.

What makes this one genuinely nasty: **every server-side check still passes.**
curl reports 200. The service log shows a successful request. The gateway log
shows a successful proxy. Only a browser refuses, only cross-origin — which is
to say, only for real users, and usually only in production.

Clause 2 is a **count** assertion for exactly this reason: not "is the header
present" but "is there exactly one".

## Running it

```bash
make test-hostile-edge
```

Applies both, runs Hydra's existing suite, asserts it **fails** and names a
clause, then reverts and re-verifies that conformance passes again. A drill that
cannot restore the environment is a failed drill.

## The rule

**Never** amend the conformance suite to make one of these pass. If a clause
cannot be satisfied by the lab gateway, that is a finding about the gateway and
it belongs in `docs/edge-finding.md` (SC-020, FR-102).
