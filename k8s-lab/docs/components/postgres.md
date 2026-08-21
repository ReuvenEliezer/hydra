# PostgreSQL

## What it is
A single-replica StatefulSet in `hydra-data`, running the **same pinned image as
the repository's `docker-compose.yml`**, with one database per service.

## Why it exists here
The services' real datastore. Version parity with local development is worth
more than chart convenience: a lab running a different Postgres is measuring a
different system.

## What problem it solves
Tenants, users, roles and orders have to live somewhere, and the schema has to be
the one Hibernate actually authors.

## How it works
`initdb` creates `auth_db` and `order_db` on first start. Credentials come from a
Secret generated at setup time. Readiness is `pg_isready` — a real check: a TCP
port check would pass while Postgres was still replaying WAL and rejecting every
connection, and every dependent pod would crash-loop against a "ready" database.

Schema is authored by a **single-instance migration Job** (D6), never by the
replicas — which run `ddl-auto=validate` and fail loudly if the schema and their
mappings diverge.

## How to inspect it
```bash
kubectl -n hydra-data exec statefulset/postgres -- psql -U "$POSTGRES_USER" -d auth_db -c '\dt'
kubectl -n hydra-data exec statefulset/postgres -- psql -U "$POSTGRES_USER" -d auth_db \
  -c 'SELECT url_identifier, status FROM tenants'
kubectl -n hydra-data logs statefulset/postgres --tail=50
```

## How to break it
```bash
kubectl -n hydra-data scale statefulset postgres --replicas=0
```
Watch: the services' readiness probes go red (readiness includes the database),
they leave the endpoint set, and the gateway returns 503. **They are not
restarted** — liveness deliberately depends on nothing external, which is what
stops a database blip becoming a rolling restart of every replica.

Subtler — break the schema and watch `validate` do its job:
```bash
kubectl -n hydra-data exec statefulset/postgres -- \
  psql -U "$POSTGRES_USER" -d auth_db -c 'ALTER TABLE tenants DROP COLUMN url_identifier CASCADE'
kubectl -n hydra-app rollout restart deploy/auth-service
```
The pods now fail at startup with a schema-validation error instead of silently
re-deriving DDL.

## How to recover it
```bash
kubectl -n hydra-data scale statefulset postgres --replicas=1
# after a schema break:
make app-deploy      # the migration Job re-authors it
```

## Production equivalent
Managed Postgres. What changes: backups, PITR, failover, connection pooling at
the edge, read replicas — and **hostPath storage becomes a network volume**,
which invalidates every stateful-failover conclusion drawn here.
