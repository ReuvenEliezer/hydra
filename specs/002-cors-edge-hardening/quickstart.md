# Quickstart: validating Browser Edge Hardening

**Feature**: `002-cors-edge-hardening` | **Date**: 2026-08-17

Runnable scenarios that prove the feature works. Each maps to requirements in [spec.md](spec.md). Implementation belongs in `tasks.md`, not here.

---

## Prerequisites

- Java 25. This repo has **no** `mvnw` wrapper script and `mvn` is not on `PATH`; invoke the wrapper distribution directly. The commands below assume:

  ```bash
  export MVN=~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn
  ```

- Docker running, for Testcontainers.
- PostgreSQL and Redis for the services: `docker compose up -d`.

Tenant subdomains of `localhost` resolve without a hosts-file entry in evergreen browsers and in the JDK HTTP client, so `acme.localhost` needs no setup.

---

## Scenario 1 — The policy is defined once

*Covers FR-001, SC-001. This is the feature's headline claim.*

1. Change `hydra.cors.allowed-origin-patterns` in **one** location.
2. Start both services.
3. Send a cross-origin request from a matching origin to each.

**Expected**: both accept it, with credentials permitted and `Retry-After` readable. No per-service code change was needed, and neither service contains a `CorsProperties` or `CorsConfig` any more.

**Counter-check that makes it meaningful**: `grep -rn "hydra.cors" --include=*.java` returns hits in `browser-edge-starter` only. A hit in either service means the duplication survived and the scenario has not actually passed.

---

## Scenario 2 — Startup refuses a dangerous configuration

*Covers FR-010, FR-018, FR-017, SC-012. Four outcomes; the differences between them are the point.*

Run each against a service and observe startup:

| Configuration | Expected outcome |
|---|---|
| `allowed-origin-patterns: https://*.hydra.example.com`, `base-domains: hydra.example.com` | Starts. `INFO` names the active patterns. |
| `allowed-origin-patterns:` (empty) | **Starts**, with a `WARN`. Cross-origin requests are then rejected at request time. |
| `allowed-origin-patterns: https://*.evil.com`, `base-domains: hydra.example.com` | **Fails to start.** Message names `https://*.evil.com`. |
| `base-domains: com` | **Fails to start.** Message names `com` as a public suffix — even though the pattern is well-formed against it. |
| `base-domains: hydra.example.com,otherapp.io` | **Fails to start.** Message names both conflicting domains. |

Row 2 versus row 3 is the intended asymmetry: an empty list is safe but useless, so it warns; an over-broad pattern would echo credentials to an arbitrary origin, so it is fatal. If both behave the same way, the implementation is wrong regardless of which way they agree.

Row 4 is the case FR-018 exists for — checking patterns alone would let one configuration error authorize `https://*.com`.

---

## Scenario 3 — Local development still works

*Covers FR-002 and guards against regressing 003.*

1. `hydra.tenant.base-domains: localhost`, `hydra.cors.allowed-origin-patterns: http://*.localhost:5173`.
2. Start auth-service and the `hydra-ui` dev server.
3. Sign in at `http://acme.localhost:5173`.

**Expected**: login succeeds, the refresh cookie is set, and token renewal works. `localhost` is a single-label base domain and MUST NOT be rejected as a public suffix — a label-count rule would break this, which is why research R3 requires a real public-suffix check.

---

## Scenario 4 — The conformance suite detects a broken edge

*Covers FR-011, FR-012, FR-015, FR-016, SC-006, SC-009. The negative case is the one that matters.*

```bash
$MVN -pl integration-tests test -Dgroups=edge-conformance
```

The suite runs against two stand-in proxies:

| Stand-in | Expected |
|---|---|
| Transparent — preserves `Host`, adds no headers | Suite **passes** |
| Hostile — rewrites `Host`, injects its own cross-origin headers | Suite **fails**, naming each violated clause |

A run where both pass is a failed validation, not a successful one: it means the assertions do not work. See [contracts/transparent-edge-contract.md](contracts/transparent-edge-contract.md).

---

## Scenario 5 — Pointing the suite at a real edge

*Covers SC-010.*

```bash
$MVN -pl integration-tests test -Dgroups=edge-conformance -Dedge.base-url=https://acme.staging.example.com
```

**Expected**: a pass/fail verdict on all five clauses, with **zero** new test code written. If validating a candidate edge requires editing tests, SC-010 has not been met.

---

## Scenario 6 — Exactly one set of headers

*Covers FR-003, FR-009, SC-002.*

1. Run the front-end against a direct-to-service deployment, then behind the transparent stand-in.
2. Inspect responses in both.

**Expected**: exactly one `Access-Control-Allow-Origin` in each, naming the single requesting origin — never a literal `*`, which browsers reject on credentialed requests. Behaviour is identical with and without the edge in the path.

---

## Scenario 7 — Preflight needs no credentials

*Covers FR-005.*

Send an unauthenticated `OPTIONS` preflight to a protected endpoint, directly and through the stand-in.

**Expected**: answered successfully in both, never `401`. The existing `OPTIONS /**` permit-all backstop in `SecurityCommons.authRules` covers the filter-ordering case and must survive this feature.

---

## Regression checks

Fast checks that the blast radius stayed where research R8 says it is:

- Tenant resolution still works — 003's tests pass unchanged, including base-domain normalization after `baseDomains` moves out of `TenantResolutionProperties`.
- `CookieUtil` is untouched: `SameSite=Strict`, `httpOnly`, host-only, path `/api/v1/auth`.
- CSRF is still disabled in both services; this feature does not relax the cookie, so FR-007 is not triggered.
- order-service still derives tenant from the JWT claim and reads no tenant header.

> **Note on the existing suite**: `hydra-ui`'s front-end tests currently fail in this environment for reasons unrelated to this feature (an `msw`/Node incompatibility, ~54 of 91 failing before any change). Do not read those failures as a regression from this work.
