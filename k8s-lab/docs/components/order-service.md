# order-service

## What it is
Hydra's real order service. Three replicas. Verifies tokens issued by
`auth-service`; does not issue any.

## Why it exists here
It makes the lab a *system* rather than a single service — and
service-to-service authentication over cluster DNS is a property worth
demonstrating.

## What problem it solves
Order CRUD, scoped to the tenant in the JWT claim.

## How it works

**It resolves `auth-service` through cluster DNS by service name:**
```
AUTH_SERVICE_URL=http://auth-service.hydra-app.svc.cluster.local:8083
```
Never a pod address. Pod addresses change on every restart, and using one
produces an outage on the next `auth-service` rollout that presents as a JWKS
failure.

**`AUTH_SERVICE_ISSUER` stays an opaque identifier** (FR-046). In this service's
configuration `jwk-set-uri` and `issuer-uri` sit adjacent, and conflating them is
an easy, silent mistake: the issuer is an identity claim to be compared, not a
location to fetch.

**Tenant scoping comes from the JWT claim**, not from `Host` — this service has
no tenant resolution of its own.

## How to inspect it
```bash
make logs WORKLOAD=order-service
TOKEN=$(curl -s --cacert .certs/lab-ca.crt -X POST https://acme.localhost/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"labuser","password":"lab-password-not-a-secret"}' | jq -r .token)
curl -s --cacert .certs/lab-ca.crt https://acme.localhost/api/orders \
  -H "Authorization: Bearer $TOKEN" | jq
```

Note the path is **`/api/orders`**, not `/api/v1/orders`. The topology contract
drew the versioned form; the code never adopted it, and the route follows the
code.

## How to break it

**Cut the JWKS path** and watch token verification fail while the service is
otherwise perfectly healthy:
```bash
kubectl -n hydra-app scale deploy auth-service --replicas=0
curl -s -o /dev/null -w '%{http_code}\n' --cacert .certs/lab-ca.crt \
  https://acme.localhost/api/orders -H "Authorization: Bearer $TOKEN"
```

**Point it at a pod address** — the mistake FR-045 exists to prevent:
```bash
POD_IP=$(kubectl -n hydra-app get pod -l app.kubernetes.io/name=auth-service \
  -o jsonpath='{.items[0].status.podIP}')
kubectl -n hydra-app set env deploy/order-service AUTH_SERVICE_URL="http://${POD_IP}:8083"
```
It works — until that pod restarts.

## How to recover it
```bash
kubectl -n hydra-app scale deploy auth-service --replicas=3
make app-deploy
make test-integration
```

## Production equivalent
The same service. What changes: its own database, real tenant domains, and a
JWKS fetch across a real network — where caching and negative-caching behaviour
suddenly matter.
