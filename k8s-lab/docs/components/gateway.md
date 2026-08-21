# Gateway API and the Gateway

## What it is
The Gateway API CRDs (standard channel), a `GatewayClass` pointing at Cilium's
controller, one `Gateway` with an HTTPS listener, and the `HTTPRoute`s attached
to it.

## Why it exists here
It is the **only** way in (FR-030). It terminates TLS, matches on path, and
forwards to ClusterIP Services — without ever touching `Host`.

## What problem it solves
One address per tenant, one certificate for all of them, one place where routing
is expressed, and **no per-tenant configuration** (FR-040).

## How it works
See [../north-south-path.md](../north-south-path.md) for every hop.

The property everything rests on: **routing is by path and `Host` is never
rewritten.** Tenant identity comes from `Host` and nothing else, so a rewrite is
a total outage rather than a degradation.

## How to inspect it
```bash
make gw-status
make gw-test
kubectl -n hydra-app get gateway hydra-gateway -o yaml
kubectl -n hydra-app get httproute -o wide
```

## How to break it

**Delete a route** — the interesting half is what still works:
```bash
kubectl -n hydra-app delete httproute hydra-api
curl --cacert .certs/lab-ca.crt https://acme.localhost/api/v1/tenant   # 404 from envoy
```
A 404 with `server: envoy` means the gateway is fine and nothing matched.

**Break the TLS reference:**
```bash
kubectl -n hydra-app delete secret hydra-lab-tls
```
The Gateway loses `ResolvedRefs` and the listener stops serving. Note that
`Programmed` may still read `True` — which is why `gw-status` checks listener
conditions separately.

**Rewrite `Host`** — the instructive one:
```bash
kubectl apply -f hostile-edge/host-rewrite.yaml
curl --cacert .certs/lab-ca.crt https://acme.localhost/api/v1/tenant
# {"status":"unknown"} — for EVERY tenant, simultaneously
```

## How to recover it
```bash
kubectl delete -f hostile-edge/ --ignore-not-found
make app-deploy
./scripts/certs.sh ensure     # if the Secret was deleted
make gw-status && make gw-test
```

## What actually went wrong here
**Cilium owns the Gateway's Service** — type LoadBalancer, no selector,
ownerReference to the Gateway. `kubectl apply` of a full Service spec fights it
over the type and port names and gets reverted. Patching only the `nodePort`
field is preserved. The symptom of getting this wrong is an allocated NodePort
that kind's port mapping does not point at, so nothing reaches the gateway at
all.

## Production equivalent
Gateway API in front of a real cloud load balancer. The route model transfers
directly; the L4 entry point does not, and every timeout tuned here will be wrong
because production latency is not microseconds.
