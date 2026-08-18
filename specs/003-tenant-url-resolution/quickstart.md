# Quickstart: validating Tenant Resolution from URL

**Feature**: `003-tenant-url-resolution` | **Plan**: [plan.md](./plan.md) | **Contracts**: [auth-service-api.md](./contracts/auth-service-api.md), [hydra-ui-api.md](./contracts/hydra-ui-api.md)

A runnable validation guide for the finished feature — what to start, what to run, and what proves each user story. It is not an implementation guide; shapes live in [data-model.md](./data-model.md) and behavior in the contracts.

---

## Prerequisites

- Java 25 (Corretto at `/usr/bin/java`) and Docker (Testcontainers + local Postgres/Redis).
- Node 22 + npm for `hydra-ui/`.
- `mvn` is **not** on PATH and there is no `./mvnw`; use the wrapper distribution directly (the `$MVN` alias below).
- A browser that resolves `*.localhost` to loopback (Chrome or Firefox). If yours does not, add to `/etc/hosts`:

  ```text
  127.0.0.1 acme.localhost system.localhost nosuch.localhost
  ```

```bash
export MVN=~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn
```

**Database wipe (required once)** — per the spec's Assumptions there is no backfill; `url_identifier` is `NOT NULL` from the first boot, so any pre-existing `tenants` rows must be gone before starting:

```bash
rm -f ~/data/auth_db.mv.db ~/data/auth_db.trace.db
```

---

## Step 1 — Automated suites

```bash
$MVN -q -pl infra-shared,rate-limit-starter,auth-service -am test
```

Expected: green, including the new `TenantHostParserTest` (the `Host` table from [data-model.md §3.1](./data-model.md)), `TenantResolutionIntegrationTest`, and `TenantProvisioningIntegrationTest`. The build also proves the removal is complete — deleting `infra-shared`'s `Headers` makes any surviving `X-Tenant-ID` sender a compile error rather than a silently ignored header.

```bash
cd hydra-ui && npm test
```

Expected: green, including the inverted login test (the request carries **no** tenant header) and `LoginForm` coverage for all five statuses.

---

## Step 2 — Start the stack

```bash
docker compose up -d postgres redis
```

```bash
$MVN -q -pl auth-service spring-boot:run
```

The `local` profile bootstraps the System Tenant with `urlIdentifier: system` and base domain `localhost`. Watch startup for the base-domain log line — an empty `hydra.tenant.base-domains` fails closed, and every address below would return `unknown`.

```bash
cd hydra-ui && npm run dev
```

---

## Step 3 — Provision a tenant (User Story 4, SC-004)

Sign in as the super-admin at `http://system.localhost:5173`, then call provisioning with its access token:

```bash
curl -i -X POST http://system.localhost:8083/api/v1/admin/tenants \
  -H "Authorization: Bearer $SUPER_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Acme Corp","urlIdentifier":"acme"}'
```

**Expect** `201` with `{id, name, urlIdentifier}`.

Then confirm each rejection — format, reserved word, and the never-reuse rule (FR-009, FR-012, FR-013):

| Body | Expect |
|---|---|
| `{"name":"X","urlIdentifier":"-bad-"}` | `400` (leading hyphen) |
| `{"name":"X","urlIdentifier":"ADMIN"}` | `400` (uppercase fails the pattern before the reserved check) |
| `{"name":"X","urlIdentifier":"admin"}` | `422` reserved word |
| `{"name":"Acme Two","urlIdentifier":"acme"}` | `422` already claimed |

For the permanence half of FR-012, delete the Acme tenant row directly in the database, then re-POST `acme` — it must **still** return `422`, because the `reserved_tenant_identifiers` row outlives the tenant.

---

## Step 4 — Sign in with no tenant field (User Story 1, SC-001/SC-002/SC-006)

Register a user into Acme (admin flow), then open `http://acme.localhost:5173`.

**Expect**:

1. The heading names the organization — `Sign in to Acme Corp` (FR-017).
2. Only Username and Password are rendered. No Tenant ID input exists, and no UUID appears anywhere in the page source (Story 1 scenario 2).
3. Submitting valid credentials signs in, against Acme.
4. In DevTools → Network: the login request carries **no** `X-Tenant-ID`, and `GET /api/v1/tenant` fired once on load with a body of exactly `{"status":"recognized","displayName":"Acme Corp"}` — no UUID field in any state (SC-006).

Directly, without the browser:

```bash
curl -s http://acme.localhost:8083/api/v1/tenant
curl -i -X POST http://acme.localhost:8083/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"alice","password":"…"}'
```

**The most common mistake this catches**: if the page is served from `acme.localhost:5173` but `apiBaseUrl` points at `http://localhost:8083`, the API request's `Host` has no tenant label and the page shows "address not recognized" while looking entirely correct. That is the constraint in [research.md R1](./research.md) — the API must be reached on the same tenant host as the page.

---

## Step 5 — Unrecognized and inactive addresses (User Story 3, SC-003)

| Address | Expect at page load, before any credentials |
|---|---|
| `http://nosuch.localhost:5173` | "address isn't recognized"; **no** username/password form rendered |
| `http://localhost:5173` (bare base domain) | same unknown state — never a default tenant |
| `http://a.b.localhost:5173` (two labels) | same unknown state |
| Acme set to a non-`ACTIVE` status, then `http://acme.localhost:5173` | A message distinct from both "not recognized" and "wrong username or password" |

Then confirm the login endpoint fails closed independently of the page (FR-006):

```bash
curl -i -X POST http://nosuch.localhost:8083/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"alice","password":"…"}'
```

**Expect** `400` with `"message":"unknown_tenant_address"` — never `401`, and never a login against some other tenant. Against an inactive tenant's address: `403` `tenant_inactive`.

Host-header normalization (FR-015) is quickest to check with an explicit header:

```bash
curl -s -H 'Host: ACME.localhost' http://127.0.0.1:8083/api/v1/tenant   # recognized (case-insensitive)
curl -s -H 'Host: acme.localhost.' http://127.0.0.1:8083/api/v1/tenant  # recognized (trailing dot)
curl -s -H 'Host: acme.evil.com'   http://127.0.0.1:8083/api/v1/tenant  # unknown (base domain not configured)
```

---

## Step 6 — Super-admin cross-tenant reach (User Story 2, SC-005)

Signed in at `http://system.localhost:5173`, register an admin into Acme:

```bash
curl -i -X POST http://system.localhost:8083/api/v1/admin/$ACME_TENANT_ID/register-admin \
  -H "Authorization: Bearer $SUPER_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"username":"acme-admin","password":"Admin@12345"}'
```

**Expect** `201`. The super-admin's login resolved strictly to the System Tenant, and their post-login authority still spans tenants — URL resolution governs login only (FR-010). This endpoint is unchanged by the feature, which is itself the point: FR-007 requires every JWT-derived tenant path to be unaffected.

---

## Step 7 — Rate limiting the lookup (FR-016)

```bash
for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code} ' http://acme.localhost:8083/api/v1/tenant; done
```

**Expect** `200`s up to the configured capacity (default 30/min), then `429` carrying `Retry-After`. The three statuses stay distinct throughout — throttling is the mitigation, not blurring the answers.

---

## Success-criteria checklist

| Criterion | Validated by |
|---|---|
| SC-001 no raw tenant identifier displayed, requested, or accepted | Step 4.2, Step 4.4 |
| SC-002 every login on a recognized address hits the correct tenant | Step 4.3, Step 5 (fail-closed), `TenantResolutionIntegrationTest` |
| SC-003 unrecognized state on load, before credentials | Step 5 |
| SC-004 provisioning alone yields a working address | Step 3 → Step 4 with no step in between |
| SC-005 super-admin spans tenants regardless of sign-in address | Step 6 |
| SC-006 display name shown; no UUID in the lookup response in any state | Step 4.1, Step 4.4, Step 5 |
