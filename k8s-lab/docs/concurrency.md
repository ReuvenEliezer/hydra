# Concurrency

Platform threads, virtual threads, and when each actually helps (FR-050).

Both services run with `spring.threads.virtual.enabled=true` by default. The
switch is configuration-only, so the benchmark can compare both modes without a
rebuild, and the active mode is **read back from the running pod** rather than
assumed.

---

## The one claim this page exists to refuse

> **Virtual threads do not inherently reduce memory consumption.**

They change *where* stack memory lives and *how* it grows. They do not make a
program need less of it, and they are not a memory optimisation.

A platform thread gets a fixed native stack — around 1 MB, reserved whether used
or not. A virtual thread's stack lives on the **heap** as a chunked
continuation, grows on demand, and is unmounted while the thread is blocked.

For **many mostly-idle** threads that is a large reduction. For a **small number
of consistently active** threads it is roughly a wash, and it can be worse: heap
stacks are garbage-collector work, and a program with thousands of live
continuations gives the collector a bigger object graph than one with a hundred
native stacks it never sees.

Anyone quoting a memory improvement from virtual threads should be asked which
of those two situations they are in.

---

## What virtual threads actually change

A virtual thread is scheduled by the JVM onto a small pool of carrier threads.
When it **blocks on I/O**, the JVM unmounts it and the carrier picks up another.
Blocking stops occupying an OS thread.

That is the whole mechanism, and it is why the benefit is entirely conditional
on what your threads are doing.

### Where they help

**Thread-per-request services that block on I/O**, which is exactly what both of
these are:

```
order-service handling a request:
  ├─ JDBC query to Postgres     ← blocks
  ├─ JWKS fetch to auth-service ← blocks
  └─ Redis command via Lettuce  ← blocks
```

With platform threads, concurrency is capped by the pool size. Two hundred
threads means two hundred in-flight requests, no matter that 195 of them are
waiting on a socket. With virtual threads the cap moves to something else —
usually the database connection pool, which is the honest bottleneck.

### Where they do not help

| Situation | Why not |
|---|---|
| **CPU-bound work** | The work still needs a core. Virtual threads add scheduling overhead and nothing else |
| **Bottleneck is downstream** | If Postgres allows 20 connections, admitting 10,000 concurrent requests produces 9,980 waiting on the pool. You have moved the queue, not shortened it |
| **Low concurrency** | At 50 concurrent requests, a platform pool is fine and simpler |
| **Pinning** (see below) | The mechanism is defeated |

**The middle row is the one that matters here.** Both services block on a
connection-pooled datastore. Virtual threads let more requests *arrive* at that
pool; they do not make it wider.

---

## Pinning — where the mechanism breaks

A virtual thread cannot unmount while it holds a native frame or is inside a
`synchronized` block. It stays **pinned** to its carrier, and a blocking call
while pinned blocks the carrier — which is a platform thread.

Enough pinned carriers and throughput collapses to the carrier pool size, which
is small. The failure mode looks like a mysterious throughput ceiling and is
easy to misdiagnose as a downstream limit.

Causes:

| Cause | Note |
|---|---|
| `synchronized` around blocking I/O | The classic. JDK 24+ improves this materially, but library code written years ago still does it |
| Native frames (JNI) | Cannot unmount, no exception |
| Some older driver internals | Worth checking a JDBC driver's release notes before assuming |

Detecting it:

```bash
kubectl -n hydra-app set env deploy/auth-service \
  JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/opentelemetry-javaagent.jar -Djdk.tracePinnedThreads=full"
kubectl -n hydra-app logs deploy/auth-service | grep -A20 'pinned'
```

Remember to set it back — that flag is for diagnosis, not for running.

---

## Daemon threads and shutdown

Virtual threads are **always daemon threads**. They do not keep the JVM alive.

The consequence people meet in production: work running on a virtual thread at
shutdown is **abandoned**, not awaited. With platform threads, a non-daemon
worker keeps the JVM up until it finishes.

For a request-handling service behind a graceful shutdown this is usually fine —
Spring stops accepting new requests and waits for in-flight ones. For background
work spawned outside the request lifecycle, it is a silent data-loss path.

This is why `terminationGracePeriodSeconds: 45` and the exec-form entrypoint
matter together: the JVM must actually **receive** SIGTERM (exec form) and have
time to drain (grace period). Shell form breaks the first, and then the grace
period is just a delay before a kill.

---

## Other limitations worth knowing

| Limitation | Consequence |
|---|---|
| `ThreadLocal` still works, but there may be a great many more threads | Per-thread caches sized for a pool of 200 behave differently with 20,000 |
| No thread pool means no natural backpressure | The pool *was* your admission control. Without it, load lands on the next bottleneck instead of queueing where you can see it |
| Debuggers and profilers vary in support | Improving, but a thread dump with 50,000 virtual threads is not something you read |
| Scheduler is a ForkJoinPool | `jdk.virtualThreadScheduler.parallelism` exists; changing it is rarely the answer |

---

## Measuring it here, honestly

```bash
make bench
```

Runs the same workload in **both** modes with the **garbage collector held
constant** (FR-104a). Varying the GC and the thread model together produces a
number that cannot be attributed to either — which is how "virtual threads made
it 20% faster" enters a codebase and never leaves.

Read `results/benchmark/<timestamp>/report.md`, and read its Limitations section
first. In particular:

- the load generator is `curl` on the same machine;
- the OTel agent is attached to every run with `always_on` sampling;
- Postgres and Redis are unloaded and local;
- concurrency is modest, which is *not* where thread-model differences become
  interesting.

If the variance across repetitions is larger than the difference between modes,
**there is no difference to report**, and the report says so rather than picking
the winner.

## Production equivalents

| Lab | Production |
|---|---|
| Mode switched by an env var | Same — it should stay configuration, so it can be reverted without a build |
| Compared on a workstation | Compared under production-shaped load, in a canary |
| Connection pool at defaults | Sized deliberately, because it is the real limit either way |
| No pinning detection running | `-Djdk.tracePinnedThreads` in a canary, or JFR events |
