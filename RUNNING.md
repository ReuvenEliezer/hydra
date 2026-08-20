# Running Hydra locally

How to get the whole stack — Postgres/Redis, `auth-service`, `order-service`, and the
`@hydra/ui` front-end — up on a development machine, and how to recognise the failures that
look like something else.

For what the modules *are*, see [README.md](./README.md). This file is only about running them.

---

## 0. Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Java | 25 | Corretto 25 at `/usr/bin/java` |
| Maven | 3.9.x | **Not on `PATH`**, and there is no `./mvnw` — see below |
| Docker | any recent | Must be running before the backend starts |
| Node | ≥ 22 | JetBrains-managed install, **not on the Bash `PATH`** — see below |

### Maven

There is no wrapper script in the repo. Use the wrapper distribution directly, or alias it:

```bash
alias mvn=~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn
```

Every `mvn` below assumes that alias (or Maven on your `PATH` some other way).

Expect `WARNING: sun.misc.Unsafe::objectFieldOffset has been called by lombok.permit.Permit`
on every build. It is Lombok under Java 25, it is pre-existing, and it is not your change.

### Node

Node lives under IntelliJ's managed install and a fresh shell often will not see it. Export it
before any `npm` command (quote it — the path contains a space):

```bash
export PATH="$HOME/Library/Application Support/JetBrains/IntelliJIdea2026.2/node/versions/24.19.0/bin:$PATH"
```

---

## 1. One-time setup

### Generate a signing key

`auth-service` signs JWTs with an RSA private key loaded from disk by `LocalKeyProvider`. The
public key and the JWKS entry are always derived from it, so this one file is all you need.
`keys/` is gitignored — a private key does not belong in version control, even as a fixture.

```bash
mkdir -p keys
openssl genpkey -algorithm RSA -out keys/jwt-private-key-local.pem -pkeyopt rsa_keygen_bits:2048
chmod 600 keys/jwt-private-key-local.pem
```

### Install front-end dependencies

```bash
npm --prefix hydra-ui install
```

### Baseline your existing local database (existing checkouts only)

As of `006-liquibase-schema-migration`, Liquibase — not Hibernate — owns the schema, and it
refuses to start against a database it has never seen before: tables exist, but no
`DATABASECHANGELOG`. Every developer's `~/data/auth_db.mv.db` and `~/data/orders_db.mv.db` was
built by the old `ddl-auto: update` mechanism, so it is exactly that "legacy" case. The **next**
`spring-boot:run` against either file fails fast with a message naming
`hydra.database.baseline.enabled=true` as the fix — this is expected, not a regression.

**Back the files up first**, then do exactly one of:

- **Reconcile once** (keeps your seeded tenant, users, and data):

  ```bash
  cp ~/data/auth_db.mv.db ~/data/auth_db.mv.db.bak
  cp ~/data/orders_db.mv.db ~/data/orders_db.mv.db.bak
  mvn -pl auth-service spring-boot:run -Dspring-boot.run.arguments=--hydra.database.baseline.enabled=true
  mvn -pl order-service spring-boot:run -Dspring-boot.run.arguments=--hydra.database.baseline.enabled=true
  ```

  Stop each service once it finishes starting (the flag is a one-time act — never leave it set
  in a run config or you will reconcile every future startup instead of just this one).

- **Delete and start fresh** (loses local data, including the bootstrap super-admin — bootstrap
  reruns automatically on an empty database):

  ```bash
  rm -f ~/data/auth_db.mv.db ~/data/auth_db.lock.db ~/data/orders_db.mv.db ~/data/orders_db.lock.db
  ```

Either way, run this once per machine, not per checkout — the database lives outside the repo.

---

## 2. Start the stack

Order matters: infrastructure, then backend, then front-end.

### Step 1 — Infrastructure

```bash
docker compose up -d
```

Starts Postgres 16 (`:5432`) and Redis 8 (`:6379`).

**Redis is required.** `auth-service` keeps refresh-token state and rate-limit buckets there;
without it, login fails even though the service appears to start. Postgres is not used by the
`local` profile — that runs on a file-backed H2 at `~/data/auth_db` — but the integration tests
and the `test` profile need a database, so leaving both up is simplest.

### Step 2 — Backend

Two env vars have no default anywhere in the repo, and `auth-service` fails fast with
`PlaceholderResolutionException` without them:

| Variable | Purpose |
|---|---|
| `JWT_PRIVATE_KEY_PATH` | The PEM from step 1 |
| `APP_BOOTSTRAP_SUPER_ADMIN_PASSWORD` | Password for the `super-admin` account created on first boot |

**From IntelliJ** (preferred): run `AuthServiceApplication` and `OrderServiceApplication`. A
shareable config with both vars already set lives at
[.run/AuthServiceApplication.run.xml](.run/AuthServiceApplication.run.xml) — edit that rather
than duplicating the settings elsewhere.

**From the command line:**

```bash
mvn -DskipTests install
```

```bash
JWT_PRIVATE_KEY_PATH="$(pwd)/keys/jwt-private-key-local.pem" \
APP_BOOTSTRAP_SUPER_ADMIN_PASSWORD='Admin@12345' \
mvn -pl auth-service spring-boot:run
```

```bash
mvn -pl order-service spring-boot:run
```

Build and run are **two separate commands on purpose**. `-am` builds the upstream modules, but
it also makes `spring-boot:run` execute against every module in the reactor — starting with the
root aggregator pom, which has no main class and dies with `Unable to find a suitable main
class`. Build dependencies first, then run the single module without `-am`.

On a first boot against an empty database you should see:

```
Bootstrapping system: creating super admin...
Super Admin 'super-admin' created.
```

That line is the whole ballgame — see [Troubleshooting](#troubleshooting) if it does not appear.

### Step 3 — Front-end

```bash
npm --prefix hydra-ui run demo
```

```bash
npm --prefix hydra-ui run storybook
```

---

## 3. URLs and credentials

| What | URL | Needs backend? |
|---|---|---|
| Demo app | **http://system.localhost:5173** | Yes |
| Storybook | http://localhost:6006 | No — fully mocked |
| auth-service | http://system.localhost:8083 | — |
| order-service | http://localhost:8082 | — |
| H2 console (auth) | http://localhost:8083/h2-console | — |

```
username: super-admin
password: whatever you set in APP_BOOTSTRAP_SUPER_ADMIN_PASSWORD
```

With the checked-in run config that password is `Admin@12345`.

---

## 4. The one rule that breaks everything

**Open the app at `system.localhost:5173`, never at `localhost:5173`.**

There is no tenant header. The tenant *is* the address the request is sent to: the label in
front of a configured base domain (`hydra.tenant.base-domains`, which is `localhost` in the
`local` and `test` profiles). The demo derives its API origin from `window.location.hostname`,
so a page served at `acme.localhost:5173` calls `acme.localhost:8083`.

Open plain `localhost:5173` and the browser calls `localhost:8083`, whose `Host` carries no
tenant label. Every lookup returns `unknown`, every login fails closed — and the UI looks
entirely correct while doing it. This is the single most likely way to get this wrong.

`*.localhost` resolves natively on macOS and in Chrome/Firefox. If yours does not, add the
addresses you use to `/etc/hosts`:

```
127.0.0.1 system.localhost acme.localhost
```

### Checking an address without signing in

```bash
curl -s http://system.localhost:8083/api/v1/tenant
```

Always returns `200`; the outcome is in the body — `recognized`, `inactive`, or `unknown`:

```json
{"status":"recognized","displayName":"System Tenant"}
```

### Signing in

```bash
curl -i -X POST http://system.localhost:8083/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"super-admin","password":"Admin@12345"}'
```

The access token comes back in the JSON body. The refresh token is set as an httpOnly cookie
scoped to `/api/v1/auth` and is never readable by JavaScript.

---

## Troubleshooting

### The sign-in page shows "We couldn't reach the server"

`HydraProvider` issues one `GET /api/v1/tenant` at mount and this is the `error` state — the
lookup itself failed rather than returning a verdict. Usually `auth-service` is not running, or
not on `:8083`. Check:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8083/actuator/health
```

Note this is deliberately distinct from "this address isn't recognized". An unreachable API is
not a wrong address, and reporting it as one sends you chasing a problem that does not exist.

### The UI sits on "Loading…" forever

The tenant lookup never settled. Open the network tab and look at the single request to
`/api/v1/tenant` — if it reads `ERR_ABORTED`, an effect cancelled it and nothing re-issued it.
This was a real bug (a StrictMode double-invocation guard cancelling the only request it
allowed) and is fixed, but the signature is worth recognising: exactly one aborted request and
no retry means the client gave up, not that the server is slow.

### `{"status":"unknown"}` at an address you expect to work

Two causes, in order of likelihood:

1. **You used a hostless address.** See [section 4](#4-the-one-rule-that-breaks-everything).
2. **Bootstrap never ran.** `BootstrapService` seeds the System Tenant *only when the `users`
   table is empty*. Any pre-existing row — including residue from an earlier run — makes it
   skip silently, with no warning in the log. There is no backfill: `url_identifier` is
   `NOT NULL UNIQUE` from the first boot.

Inspect the database at http://localhost:8083/h2-console (JDBC URL from
`application-local.yml`, user `sa`, empty password) and check `select * from tenants`. If you
see anything other than your own tenants, reset:

```bash
rm -f ~/data/auth_db.mv.db ~/data/auth_db.lock.db
```

**Stop `auth-service` first** — deleting a live H2 file corrupts it. Restart and the bootstrap
log line reappears.

### `400 unknown_tenant_address` on login

The address named no tenant, and this is returned *before* credentials are read. Two other
codes are worth telling apart:

| Code | Meaning |
|---|---|
| `400 unknown_tenant_address` | The address maps to no organization |
| `403 tenant_inactive` | The organization exists here but is switched off |
| `401 Invalid credentials` | The only one actually about your username or password |

### CORS errors in the browser console

Both services allow **origin patterns**, not literal origins — every tenant is its own origin,
so a fixed list would need an entry per tenant. The `local` profile already covers the demo and
Storybook:

```yaml
hydra:
  cors:
    allowed-origin-patterns: http://*.localhost:5173,http://*.localhost:6006
```

If you serve the front-end from another port, add it there. A pattern is not `*`: Spring echoes
back the single matched origin, which is what keeps `allowCredentials(true)` legal.

### Vite rejects the host

Vite 6 refuses requests whose `Host` is not in its allow-list (DNS-rebinding protection). Since
the subdomain *is* the tenant, every meaningful dev address is a subdomain, so
[vite.demo.config.ts](hydra-ui/vite.demo.config.ts) sets `allowedHosts: [".localhost"]`. If you
move to a different base domain, that list needs the same treatment.

---

## Running the tests

```bash
mvn test
```

```bash
npm --prefix hydra-ui run test
```

Backend integration tests are self-contained: `auth-service` uses Testcontainers, and the
cross-service test runs both services against throwaway in-memory H2 databases. Neither touches
`~/data/` — if a test run ever leaves rows in your development database again, that isolation
has regressed and is the bug worth chasing.
