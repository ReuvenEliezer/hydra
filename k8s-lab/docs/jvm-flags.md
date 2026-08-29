# JVM flags in the service images

Both service images pass JVM flags on the entrypoint. FR-059 requires removing
any flag that is **provably inert** and FR-059a requires documenting every flag
that is retained. This page records the measurements those decisions were made
from — not opinions about the flags, but what the JVM actually did when asked.

All measurements below were executed on this workstation
(macOS arm64, Docker 29.4.0) against `eclipse-temurin:25-jre-alpine`, which is
the pinned runtime image (`JAVA_RUNTIME_IMAGE` in `versions.env`).

```
openjdk version "25.0.3" 2026-04-21 LTS
OpenJDK Runtime Environment Temurin-25.0.3+9 (build 25.0.3+9-LTS)
```

---

## `-XX:+ZGenerational` — REMOVED

### The question

Non-generational ZGC was removed in JDK 24, at which point `ZGenerational`
became obsolete. Obsolete flags are typically *removed* one release later, and a
removed flag makes the JVM refuse to start. Research finding A5 raised this as a
possible **live bug**: if the flag were fatal on Java 25, the current images
would not start at all, and removing it would be a bug fix rather than a
cleanup — a difference that belongs in the commit message.

### The measurement (D3's validation obligation)

```bash
docker run --rm eclipse-temurin:25-jre-alpine \
  java -XX:+UseZGC -XX:+ZGenerational -version
```

Result:

```
OpenJDK 64-Bit Server VM warning: Ignoring option ZGenerational; support was removed in 24.0
openjdk version "25.0.3" 2026-04-21 LTS
...
exit code 0
```

### The verdict

**Warned, not fatal.** The JVM starts, prints a warning to stderr and ignores
the flag. So:

- The current images **do** start. This is a cleanup, not a live bug fix, and
  the commit message says so rather than claiming a fix that did not happen.
- The flag is provably inert — the JVM says outright that it is ignoring it —
  so FR-059 requires its removal, and removal changes nothing observable except
  one fewer warning line at every container start.

That warning line was not harmless in one respect: it appears on stderr at
every pod start, which in a lab whose whole point is teaching people to read
logs is a small permanent piece of noise that means nothing.

---

## `-XX:+UseZGC` — RETAINED, and deliberately not decided here

Kept exactly as it was. This is a genuine behavioural choice, not an inert flag,
and **this feature does not make it**.

A collector selected on an arm64 laptop under a synthetic workload is not a
collector selected for production. What the lab can honestly contribute is a
measurement, which is what `tests/perf/gc-comparison.sh` produces: ZGC against
the runtime default, same workload, same everything else. That comparison is
published as a recommendation feeding a **separate** decision (FR-059a), and
this document will not pre-empt it.

---

## `-Djava.security.egd=file:/dev/./urandom` — RETAINED, and the reason is a finding

### The expectation

Research decision D3 listed this as the second removal candidate, on the
widespread understanding that it "has been a no-op on modern JDKs for years".
D3 attached a condition to acting on that: remove it **only if** the measurement
shows no difference.

### The measurement

It is not a no-op. It changes which `SecureRandom` implementation the JVM
selects.

`securerandom.source` in this image's `java.security`:

```
securerandom.source=file:/dev/random
```

Running a class that constructs `new SecureRandom()` and reports the algorithm
it resolved to, plus the time to seed and draw 64×32 bytes:

| Configuration | Algorithm selected | seed + 64×32B |
|---|---|---|
| No flag | `NativePRNG` | 11–13 ms |
| `-Djava.security.egd=file:/dev/./urandom` | **`DRBG`** | 16–17 ms |

Four runs each; the values above are the observed ranges.

Whole-process wall clock (JVM start through the same work, six runs each):

| Configuration | Observed (ms) |
|---|---|
| No flag | 35, 30, 32, 31, 29, 28 |
| With the flag | 32, 33, 33, 35, 30, 31 |

Container entropy available: 256.

### The verdict

**Retained.** Two independent reasons, and the first is sufficient on its own:

1. **It is not inert, so FR-059 does not reach it.** FR-059 draws its line at
   provable inertness. This flag provably changes the selected `SecureRandom`
   implementation from `NativePRNG` to `DRBG` — and `auth-service` uses
   `SecureRandom` on paths that matter, since it issues credentials. Removing it
   would be a change to the cryptographic primitive the service seeds with,
   made as a side effect of a Dockerfile tidy-up. That is not a cleanup.

2. **The performance story does not support removal either.** The flag is
   marginally *slower* here, not faster — the opposite of the folklore that
   motivates adding it. The wall-clock difference is inside the run-to-run
   spread and supports no conclusion at all.

The mechanism, for the record: historically the `SUN` provider special-cases
`file:/dev/random` and `file:/dev/urandom` to select `NativePRNG`. The inserted
`/./` defeats that string match, so the special case does not fire and the
configured default (`DRBG`) is used instead. This is why the "harmless
no-op" reputation is wrong: the flag was always doing something, and what it does
is choose a different algorithm.

### What this leaves open

Whether `DRBG` or `NativePRNG` is the right choice for these services is a real
question with a real answer, and it is **not this feature's question**. It is
recorded in [known-gaps.md](known-gaps.md) as a divergence someone should decide
deliberately rather than inherit. What the lab has established is only that the
choice is currently being made by a flag most people believe does nothing.

---

## Flags NOT added

| Not added | Why |
|---|---|
| `-XX:MaxRAMPercentage` | Sizing the heap against the container limit is a real decision that needs measurement (`docs/memory.md`, `docs/resource-tuning.md`). Setting it here would bake in a guess and make the memory documentation a description of that guess. |
| `-XX:+UseContainerSupport` | On by default since JDK 10. Adding it would be exactly the kind of inert flag FR-059 exists to remove. |
| `-XX:+ExitOnOutOfMemoryError` | Defensible, and a behavioural change to a running service. Out of scope under FR-044. |
| `-XX:+HeapDumpOnOutOfMemoryError` | Same, plus it needs a writable path, and the containers run with a read-only root filesystem. |

## Where the flags live

`auth-service/Dockerfile` and `order-service/Dockerfile`, in the exec-form
`ENTRYPOINT`. Exec form matters independently of the flags: it makes the JVM
PID 1's direct child so it receives `SIGTERM`, which is what makes graceful
shutdown work at all (FR-058).

`JAVA_TOOL_OPTIONS` is **not** set in either image. The OpenTelemetry agent is
baked in at `/opt/otel/opentelemetry-javaagent.jar` and is inert unless the
chart supplies that variable (D10) — so the image is not permanently coupled to
the lab's observability stack.
