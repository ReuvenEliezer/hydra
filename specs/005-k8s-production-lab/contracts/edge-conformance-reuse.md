# Contract: Edge Conformance Reuse

**Feature**: `005-k8s-production-lab` | Satisfies: FR-035, FR-042, FR-096, FR-032b, SC-005, SC-020

The transparent edge contract already exists ([002-cors-edge-hardening/contracts/transparent-edge-contract.md](../../002-cors-edge-hardening/contracts/transparent-edge-contract.md)) and so does its executable suite. This lab does not write a new one. It points the existing one at a real gateway — which is the first time that contract has met anything other than a stand-in.

## The reuse mechanism, in full

```bash
mvn -pl integration-tests test \
  -Dgroups=edge-conformance \
  -Dedge.base-url=https://acme.localhost \
  -Djavax.net.ssl.trustStore=k8s-lab/.certs/lab-truststore.p12 \
  -Djavax.net.ssl.trustStorePassword=<from setup> \
  -Djavax.net.ssl.trustStoreType=PKCS12
```

That is the entire integration. Three facts make it work, all confirmed against source:

1. **`TransparentEdgeConformanceTest` already reads `-Dedge.base-url`** and skips its nginx stand-in when the property is set. This was designed in during 002 and is documented in the contract's Verification section.
2. **`EdgeConformanceAssertions` builds every client with `HttpClients.createDefault()`**, which resolves the JVM's default `SSLContext`. So the lab's CA is handed to the suite entirely through standard JVM system properties — no code change (FR-032b).
3. **The suite's tenant constants are `acme.localhost` and `beta.localhost`**, which are exactly the hostnames the lab serves (research.md D8). Nothing needs overriding.

## Binding prohibitions

| Prohibition | Why |
|---|---|
| No assertion in the suite may be modified, extended or relaxed | SC-020, FR-102. If a clause cannot be satisfied by the lab gateway, that is a finding about the gateway — not a reason to amend the contract |
| Certificate verification MUST NOT be disabled | A harness that skips verification cannot test the `Secure` credential clause it exists to test (FR-032b, spec edge case) |
| No plain-HTTP run may substitute for the TLS run | FR-032 is blocking with no fallback. A conformance pass over HTTP does not satisfy SC-005 |
| The suite MUST be run against **both** targets | A pass alone proves nothing (FR-042) |

## Required outcomes

| Target | Base URL | Expected |
|---|---|---|
| Lab gateway | `https://acme.localhost` | **All clauses pass**, over TLS, with verification enabled |
| Hostile gateway | same, with `k8s-lab/hostile-edge/` applied | **Fails**, naming the violated clause |

## The hostile configuration

`k8s-lab/hostile-edge/` MUST deliberately violate at least two clauses in ways a real gateway plausibly would by accident:

- **Clause 1** — an `HTTPRoute` `RequestHeaderModifier` that rewrites `Host` to the backend service name. This is the single most common gateway default in the wild, and against Hydra it is a total outage: tenant identity comes solely from `Host`, so every tenant resolves to `unknown`.
- **Clause 2** — gateway-emitted CORS response headers. Many gateways ship this enabled. With the service also emitting, the browser sees two `Access-Control-Allow-Origin` values and rejects the response.

Applying it MUST be one documented command, and reverting it MUST return the environment to a state where the conformance run passes again.

## Clauses the lab exercises that the stand-in could not

The stand-in proxies verified the contract's logic. A real gateway terminating TLS verifies things they structurally could not:

| Clause | What only the real gateway proves |
|---|---|
| 1 — `Host` preserved | Preserved **through TLS termination and host-based routing**, not just through a transparent pass-through |
| 4 — credential untouched | The `Secure` attribute is exercised as issued, because the transport is genuinely encrypted (FR-032) |
| 5 — no per-tenant configuration | A tenant added *after* the gateway was programmed works with zero gateway objects changed — proven against a live control plane (SC-007) |

## Beyond the contract

Two lab requirements go past the existing suite and therefore live in `k8s-lab/tests/`, **not** in the Java suite:

- **FR-041 / SC-006** — a forged `X-Forwarded-For` MUST NOT be honoured. The gateway replaces rather than appends, so the rate limiter counts against the address the gateway observed. This is the lab's highest-risk requirement (research.md D12); if it cannot be satisfied, it is reported as a failure and recorded in the Edge Finding as evidence, not smoothed over.
- **FR-036 addendum** — `Host` preservation verified from the workstation over TLS end to end.
