# Memory

Where a JVM's memory actually goes, and why the container limit is **not** the
maximum heap size (FR-060).

This page exists because the single most common Kubernetes-plus-JVM mistake is
setting `-Xmx` equal to `resources.limits.memory` and being surprised by
`OOMKilled`.

---

## The container limit is not the heap

A container is killed on its **total resident memory**, not its heap. The heap
is one of at least seven things inside that limit.

```
┌─ container memory limit ────────────────────────────────────┐
│                                                             │
│  ┌─ JVM heap ──────────────────┐   -Xmx / MaxRAMPercentage  │
│  │  young + old generations    │   the only part -Xmx bounds│
│  └─────────────────────────────┘                            │
│                                                             │
│  ┌─ class metadata (Metaspace) ┐   grows with the APP, not  │
│  │  loaded classes, methods     │   with the workload        │
│  └─────────────────────────────┘                            │
│  ┌─ code cache ────────────────┐   JIT-compiled native code │
│  ┌─ direct byte buffers ───────┐   NIO, Netty, Lettuce      │
│  ┌─ thread stacks ─────────────┐   ~1 MB each, x threads    │
│  ┌─ GC metadata ───────────────┐   the collector's own      │
│  ┌─ native allocations ────────┐   JNI, compression, TLS    │
│  └─ the JVM binary + libs ─────┘                            │
└─────────────────────────────────────────────────────────────┘
```

**`-Xmx` bounds only the first box.** Everything else is additional, and most of
it is invisible to every JVM-side metric people habitually look at.

## What each part actually does

### Heap
Where objects live. The only region `-Xmx` controls, and the only one most
dashboards show. Reported by `jvm_memory_used_bytes{jvm_memory_type="heap"}`.

`used` and `committed` are different numbers and the difference matters:
**committed** is what the JVM has taken from the OS and is what counts toward
the container limit. A heap that is 30% used but fully committed occupies all of
it as far as the kernel is concerned.

### Class metadata (Metaspace)
Class structures, method metadata, constant pools. **Grows with the size of the
application, not with traffic** — a Spring Boot service with a large dependency
tree loads thousands of classes at startup and then stops. Unbounded by default.

Two paths blow it up: dynamic proxy generation (Spring creates plenty) and
repeated redeployment inside one JVM (not a concern here).

### Code cache
JIT-compiled native code. Grows through warm-up and plateaus. When it fills, the
JVM falls back to interpreting and everything gets slower with no error message
— a performance cliff that looks like a downstream problem.

### Direct byte buffers
Off-heap, allocated by NIO. **Netty and Lettuce both use them heavily**, so both
services have real direct-buffer usage: Netty under Tomcat's connector, Lettuce
for every Redis command.

Bounded by `-XX:MaxDirectMemorySize`, which defaults to roughly `-Xmx` — so the
naive `-Xmx == limit` produces a JVM permitted to allocate **twice the limit**
before either bound complains.

### Thread stacks
~1 MB per platform thread by default. A thread pool of 200 is ~200 MB that no
heap metric shows.

Virtual threads change the arithmetic — their stacks live on the heap and grow
on demand — but see [concurrency.md](concurrency.md): that is **not** the same
claim as "virtual threads reduce memory consumption".

### GC metadata
The collector's own bookkeeping. ZGC keeps forwarding tables and mark stacks;
their cost scales with heap size and object graph shape.

### Native allocations
JNI, compression, TLS, and the JVM binary and its shared libraries.

---

## The rule

> **Do not set maximum heap size equal to the container memory limit.**

Leave headroom for everything above. How much depends on the application's class
count, its thread model and its direct-buffer usage — which is exactly why the
lab **does not set `-Xmx` at all**.

Modern JVMs are container-aware and size the heap from the limit
(`MaxRAMPercentage`, default 25%). That default is conservative, and raising it
is a legitimate tuning decision. It is a decision that should follow a
measurement, not a Dockerfile edit — see
[resource-tuning.md](resource-tuning.md).

## Measuring it here

Grafana → **Hydra — runtime, resources and scaling**. The panels are deliberately
adjacent:

| Panel | Answers |
|---|---|
| JVM heap used vs committed | how much of the heap is live, and how much is claimed from the OS |
| JVM non-heap (metaspace, code cache) | the parts no `-Xmx` bounds |
| Container memory vs limit | what the **kernel** sees — what the OOM killer acts on |

**The gap between the last two is everything on this page.**

```bash
make console-metrics

kubectl -n hydra-app exec deploy/auth-service -- \
  jcmd 1 VM.native_memory summary     # if NMT is enabled
kubectl top pods -n hydra-app          # the kernel's view
```

## Diagnosing OOMKilled

```bash
kubectl -n hydra-app describe pod <pod> | grep -A5 'Last State'
```

`Reason: OOMKilled` with `Exit Code: 137` means the **kernel** killed it. Note
what it does *not* mean: it is not a Java `OutOfMemoryError`. A Java OOM is an
exception with a stack trace and a heap that hit `-Xmx`. Exit 137 means total
resident memory hit the container limit, and the heap may have been half empty.

Order of investigation:

1. Container memory vs limit — was it climbing steadily, or did it spike?
2. Heap committed — if heap is small and the container is at its limit, the
   answer is off-heap and nothing on the heap graph will show it.
3. Metaspace — steady growth after warm-up suggests class-loading pressure.
4. Thread count × ~1 MB — a thread leak is a memory leak that no heap dump finds.
5. Direct buffers — the usual culprit when nothing else accounts for it.

## Production equivalents

| Lab | Production |
|---|---|
| No `-Xmx`; JVM sizes from the limit | Same, with `MaxRAMPercentage` set from measurement |
| Requests and limits are starting points | Derived from observed p99 under real traffic |
| No `-XX:+HeapDumpOnOutOfMemoryError` | Enabled, writing to a mounted volume |
| Native Memory Tracking off | Enabled in a canary; it costs a few percent |
| Memory read from a dashboard | Alerts on working-set approaching the limit, before the kill |
