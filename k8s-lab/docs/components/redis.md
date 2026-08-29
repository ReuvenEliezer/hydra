# Redis

## What it is
A single-replica StatefulSet in `hydra-data`, same pinned image as
`docker-compose.yml`, password-protected from a Secret.

## Why it exists here
Rate limiting (Bucket4j) and refresh-token rotation. Both are **distributed
state**, which is the whole reason they need a shared store rather than
per-process memory.

## What problem it solves
Two properties that are impossible without it:

- A rate limit of N means N **across all replicas**, not N per replica.
- Credential rotation is **atomic across replicas** — the Lua script executes
  server-side, so concurrent presentations of one credential cannot both win.

## How it works
`requirepass` from a Secret. Readiness runs an **authenticated** `redis-cli ping`
— an unauthenticated ping returns `NOAUTH`, which is a *response*, so a naive
ping check passes on a server no client can use.

## How to inspect it
```bash
kubectl -n hydra-data exec statefulset/redis -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'
kubectl -n hydra-data exec statefulset/redis -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning keys "*"' | head
```

## How to break it
```bash
make test-failure   # includes cache-down
# or:
kubectl -n hydra-data scale statefulset redis --replicas=0
```

**What you should see is a rejection, not a pass-through.** Rate limiting fails
**closed** (`rate-limit.fail-open: false`), so losing Redis rejects requests
rather than letting them through unthrottled.

That is deliberate and it is a security posture: an attacker who can take out the
cache must not thereby remove the rate limit. The lab demonstrates it on purpose
so it is a known property rather than a discovery during an incident.

## How to recover it
```bash
kubectl -n hydra-data scale statefulset redis --replicas=1
make test-smoke
```

## Production equivalent
A managed cache. What changes: replication and failover, TLS in transit, an auth
token from a real secret store, and eviction policy — which matters here because
rate-limit buckets and rotation state have *very* different tolerance for being
evicted.
