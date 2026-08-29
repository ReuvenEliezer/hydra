# auth-service

## What it is
Hydra's real authentication service — the same code, built from this
repository's own reactor. Three replicas.

## Why it exists here
It is the point. The lab runs Hydra, not a stand-in.

## What problem it solves
Tenant resolution from `Host`, sign-in, JWT issuance, refresh-token rotation, and
publishing a JWKS key set for `order-service` to verify against.

## How it works

**Tenant identity comes from the address.** `hydra.tenant.base-domains=localhost`
means the single label in front of it names a tenant. No header, query parameter
or body field can name one — which is why `Host` preservation is the property the
whole edge contract turns on.

**Every replica mounts the SAME signing key Secret** (FR-047). A token issued by
one replica validates against the key set published by any other, by
construction rather than coincidence. Under the `test` profile,
`LocalKeyProvider` reads `jwt.private-key-path` from a file, and a mounted Secret
is exactly that.

**Refresh rotation is atomic across replicas.** A Lua script executes
server-side in Redis, so concurrent presentations of one credential cannot both
create new state. `refresh-token.grace-ttl` (PT5S) then returns the *same* new
token to a retrying client rather than logging them out.

## How to inspect it
```bash
make app-status
make logs WORKLOAD=auth-service
curl --cacert .certs/lab-ca.crt https://acme.localhost/api/v1/tenant
curl --cacert .certs/lab-ca.crt https://acme.localhost/.well-known/jwks.json | jq
```

## How to break it

**Delete a replica** — nothing should be observable to a client:
```bash
make test-pod-failure
```

**Break the signing key** and watch FR-047 stop being true:
```bash
kubectl -n hydra-app delete secret hydra-jwt-signing-key
kubectl -n hydra-app rollout restart deploy/auth-service
```
The pods fail at startup — under `test`, no `KeyProvider` bean means no context.

**Exhaust the rate limit:**
```bash
for i in $(seq 1 20); do curl -s -o /dev/null -w '%{http_code} ' --cacert .certs/lab-ca.crt \
  -X POST https://acme.localhost/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"labuser","password":"wrong-but-long-enough"}'; done
```
Note the password must be **≥8 characters**: shorter fails bean validation at
argument binding and never reaches the rate-limit aspect at all.

## How to recover it
```bash
./scripts/app.sh secrets      # regenerates the Secret if deleted
make app-deploy
make test-smoke
```

## Production equivalent
The same service. What changes: `CloudKeyProvider` reading from AWS Secrets
Manager (the code path already exists), a real certificate, real tenant domains,
and a `prod` profile instead of `test` — which the lab runs only because it is
the one profile binding a file-based `KeyProvider`
([known-gaps.md](../known-gaps.md) §7).
