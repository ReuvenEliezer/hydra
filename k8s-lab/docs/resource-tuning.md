# Resource tuning

How to revise the resource requests and limits **from measurement** (FR-062).

> **The values shipped in `values.yaml` are starting points, not measured
> settings.** They were chosen to fit a workstation. Nothing about them is
> derived from observation, and they should not be copied anywhere.

---

## The rule that matters most

> **Lowering a limit MUST be supported by measurement, and MUST NOT be justified
> by the choice of concurrency model.**

"We switched to virtual threads, so we can cut the memory limit" is the specific
sentence this rule exists to stop. Virtual threads change *where* stack memory
lives, not how much memory a program needs — see
[concurrency.md](concurrency.md). A limit lowered on that reasoning gets
discovered as `OOMKilled` under load, which is the worst possible time.

If a limit comes down, the justification is a graph.

---

## What is currently set, and why it is not measured

```yaml
auth:
  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits:   {memory: 1Gi}
```

**There is no CPU limit, and that is deliberate.** A CPU limit throttles rather
than terminates, and CFS throttling on a JVM produces latency spikes that are
indistinguishable from GC pauses in a benchmark. Requests give the scheduler
what it needs; a limit would corrupt the measurement US6 exists to take.

The memory limit exists because memory pressure is not gradual — without a
limit, one leaking pod takes the node.

---

## The workflow

### 1. Establish a baseline

```bash
make setup
make console-metrics     # → "Hydra — runtime, resources and scaling"
```

Let it idle for a few minutes. Note **committed** heap, not used: committed is
what the JVM has taken from the OS, and it is what counts toward the limit.

### 2. Drive representative load

```bash
DURATION=300 CONCURRENCY=24 make load-test
```

Representative is doing real work. The lab's endpoints block on Postgres and
Redis for exactly this reason (FR-104) — an endpoint that returns a constant
measures serialisation, not the service.

### 3. Read the panels together

The runtime dashboard puts these adjacent on purpose:

| Panel | Question |
|---|---|
| JVM heap used vs committed | how much is live, how much is claimed |
| JVM non-heap | the parts `-Xmx` does not bound |
| Container memory vs limit | what the **kernel** sees — what the OOM killer acts on |
| GC collections/sec and pause duration | frequent-and-short vs rare-and-long are different problems |
| Container CPU vs request | is the HPA's utilisation target even reachable? |
| RED (repeated at the bottom) | did any of this show up as latency? |

**The gap between JVM heap and container memory is the whole subject of
[memory.md](memory.md).** If they are far apart, the answer is off-heap and no
heap graph will show it.

### 4. Run the benchmark for numbers you can compare

```bash
make bench
```

Writes `results/benchmark/<timestamp>/report.md` with **repeated runs and
observed variance** (SC-017). Read the Limitations section first.

### 5. Change one thing, re-measure, compare

```bash
helm upgrade hydra-lab charts/hydra-lab -n hydra-app --reuse-values \
  --set auth.resources.limits.memory=768Mi
```

Then repeat steps 2–4 and compare against the previous report.

---

## Telling signal from noise

This is where tuning usually goes wrong.

**Rule: the difference between two configurations must be larger than the spread
across repetitions of one configuration.** If p99 varies 180–240 ms across three
identical runs, a change from 210 ms to 200 ms is nothing.

The benchmark reports ranges rather than single figures precisely so this
comparison is available. A single number invites a conclusion the data does not
support.

Things that produce noise on a workstation:

| Source | Effect |
|---|---|
| Browser, IDE, other containers | CPU contention, unpredictable |
| Docker Desktop's VM | its own scheduler and memory ceiling between you and the metrics |
| JIT warm-up | the first minute is a different program; the benchmark discards a warm-up window |
| GC timing | a collection during a measurement window skews a p99 |
| Page cache | the second run reads from memory |

Mitigations: at least three repetitions, warm-up discarded, nothing else running,
same machine, same session.

---

## Signals worth acting on

| Observation | Likely meaning | Action |
|---|---|---|
| Container memory near the limit, heap far below | Off-heap: metaspace, direct buffers, thread stacks | **Raise** the limit, or find the off-heap consumer. Do not lower it |
| Heap committed at max, frequent GC, rising pause time | Genuine heap pressure | Raise the limit, or reduce allocation |
| CPU steady well under the request | Over-requested | Lower the **request** — this improves scheduling density and is the safest change here |
| CPU at the request, HPA not scaling | The target may be unreachable, or there is no headroom | Check `ScalingActive` before concluding anything (FR-072) |
| p99 spikes matching GC pauses | Collector behaviour | A GC question, not a limit question. See `gc-comparison.sh` |
| p99 spikes with no GC correlation | Downstream, or CFS throttling | Check whether a CPU limit was added |
| Memory climbing steadily, never plateauing | A leak | A limit change hides it. Take a heap dump |

**The first row is the most common and the most misread.** "Container memory is
high, so the JVM needs more heap" is usually backwards: the JVM has plenty of
heap and something off-heap is growing.

---

## When the workstation is the limit

Sometimes there is no headroom to measure anything, and the honest answer is to
say so. `tests/perf/scaling.sh` distinguishes two cases that look identical:

- **"did not scale"** — the HPA had metrics and did not act;
- **"could not observe"** — the HPA had no metrics at all.

It never reports success for either (FR-072, SC-016). If the workstation cannot
supply the headroom, the constraint is reported and the number is not
manufactured.

`make setup-reduced` trims resources further and prints exactly which scenarios
that makes unavailable.

---

## Recording a change

A tuning change is not finished until it is written down:

1. What was changed, and from what to what.
2. **The measurement that justified it** — a link to a benchmark report or a
   dashboard screenshot with a timestamp.
3. The variance across repetitions, so a reader can judge the signal.
4. What was *not* measured, and therefore what the change might break.

Point 3 is the one people skip, and it is the one that makes the change
reviewable.

---

## Production

None of these numbers transfer. Production tuning uses production traffic on
production hardware:

| Lab | Production |
|---|---|
| Synthetic load on a laptop | Real traffic in a canary |
| Three repetitions in one session | Days of observation across diurnal cycles |
| One workload shape | The full mix, including the rare expensive path |
| No CPU limit (deliberately, to protect the measurement) | Reconsider — throttling may be preferable to node contention |
| Limits from a workstation | Limits from p99 headroom under peak, plus margin for the paths you have not seen |
