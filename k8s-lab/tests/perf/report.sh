#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# report.sh — the Benchmark Report (FR-106, FR-107, SC-017, data-model §12).
#
# Generates results/benchmark/<timestamp>/report.md.
#
# The Limitations section is not boilerplate and is not optional. FR-106 lists
# what it must cover and FR-107 forbids conclusions the measurements do not
# support — so the report states what it measured, states what it cannot tell
# you, and draws no conclusion at all. Conclusions are for a reader with
# context this script does not have.
# ---------------------------------------------------------------------------
set -uo pipefail

RUN_DIR="${1:?usage: report.sh <run-dir> <duration> <concurrency> <repeats> <gc>}"
DURATION="${2:-90}"; CONCURRENCY="${3:-16}"; REPEATS="${4:-3}"; GC_MODE="${5:-UseZGC}"
OUT="${RUN_DIR}/report.md"

hw() { sed -n "s/^$1=//p" "${RUN_DIR}/hardware.env" 2>/dev/null | head -1; }

stat_of() {
  local f="$1/raw.csv"
  [[ -r "$f" ]] || { printf 'n/a'; return; }
  case "$2" in
    total)     wc -l < "$f" | tr -d ' ' ;;
    ok)        awk -F, '$1 ~ /^2/' "$f" | wc -l | tr -d ' ' ;;
    throttled) awk -F, '$1 == 429' "$f" | wc -l | tr -d ' ' ;;
    errors)    awk -F, '$1 ~ /^5/ || $1 == "000"' "$f" | wc -l | tr -d ' ' ;;
    rps)       awk -v d="$DURATION" 'END { if (NR==0) printf "n/a"; else printf "%.1f", NR/d }' "$f" ;;
    p50|p95|p99)
      awk -F, -v p="${2#p}" '$2>0 { print $2 }' "$f" | sort -n | \
        awk -v p="${2#p}" '{a[NR]=$1} END { if(NR==0){printf "n/a";exit} printf "%.3f", a[int(NR*p/100)+(int(NR*p/100)<NR?1:0)] }' ;;
  esac
}

variance_row() {   # variance_row <mode> <stat>
  local mode="$1" stat="$2" vals="" d
  for d in "${RUN_DIR}/${mode}-rep"*; do
    [[ -d "$d" ]] || continue
    vals+="$(stat_of "$d" "$stat") "
  done
  printf '%s' "$vals"
}

spread() {   # spread <values...> -> "min–max (n runs)"
  printf '%s\n' $1 | grep -v 'n/a' | sort -n | awk '
    { a[NR]=$1 }
    END { if (NR==0) { print "n/a"; exit }
          if (NR==1) { printf "%s (1 run)", a[1]; exit }
          printf "%s – %s (%d runs)", a[1], a[NR], NR }'
}

{
cat <<HEADER
# Benchmark report

Generated $(date -u '+%Y-%m-%dT%H:%M:%SZ') by \`make bench\`.

> **Read the Limitations section before quoting any number from this report.**
> Every figure below describes one workstation running one synthetic workload.
> None of them is a production capacity estimate, and this report deliberately
> draws no conclusion — it reports what was measured (FR-107).

## Configuration

| | |
|---|---|
| Concurrency modes compared | virtual threads vs platform threads |
| **Garbage collector** | **\`-XX:+${GC_MODE}\`, HELD CONSTANT across both modes (FR-104a)** |
| Replicas | $(cat "${RUN_DIR}"/virtual-rep1/replicas.txt 2>/dev/null | tr '\n' ' ' || echo 'n/a') |
| Load duration | ${DURATION}s per repetition |
| Concurrency | ${CONCURRENCY} concurrent clients |
| Repetitions | ${REPEATS} per mode |
| Warm-up | discarded before each measured run |
| Trace sampling | \`always_on\` — a lab setting, and it costs something (see Limitations) |
| OTel Java agent | ${OTEL_JAVA_AGENT_VERSION}, attached to every run |
| Image tag | $(hw image_tag) |

Holding the collector constant is the point of the comparison. Varying the GC
and the concurrency model together produces a number that cannot be attributed
to either, and that number is how "virtual threads made it faster" enters a
codebase and never leaves.

## Hardware

| | |
|---|---|
| CPU | $(hw cpu_model) |
| Cores | $(hw cpu_cores) |
| Memory | $(hw memory_gb) GB |
| Architecture | $(hw arch) |
| OS | $(hw os) |
| Container runtime | $(hw container_runtime) |
| Kubernetes | $(hw kubernetes) |

## Load profile

Two endpoints, alternating, both of which **block on real I/O** (FR-104):

| Endpoint | Blocks on |
|---|---|
| \`GET /api/v1/tenant\` | Postgres (tenant lookup) and Redis (rate limiter) |
| \`GET /api/orders\` | Postgres (authenticated order read) |

All traffic goes **through the gateway** over TLS — the same path a real client
takes (FR-071). A benchmark that bypasses the edge measures a system nobody runs.

## Results

Ranges are across ${REPEATS} repetitions. A single figure would be an anecdote
with a decimal point (SC-017).

| Metric | Virtual threads | Platform threads |
|---|---|---|
| Requests/sec | $(spread "$(variance_row virtual rps)") | $(spread "$(variance_row platform rps)") |
| p50 latency (s) | $(spread "$(variance_row virtual p50)") | $(spread "$(variance_row platform p50)") |
| p95 latency (s) | $(spread "$(variance_row virtual p95)") | $(spread "$(variance_row platform p95)") |
| p99 latency (s) | $(spread "$(variance_row virtual p99)") | $(spread "$(variance_row platform p99)") |
| 2xx | $(spread "$(variance_row virtual ok)") | $(spread "$(variance_row platform ok)") |
| **429 (throttled)** | $(spread "$(variance_row virtual throttled)") | $(spread "$(variance_row platform throttled)") |
| 5xx / no response | $(spread "$(variance_row virtual errors)") | $(spread "$(variance_row platform errors)") |

**429s are listed separately from errors and always will be (FR-105, D11).** A
throttled request is the rate limiter doing its job. Folding it into an error
rate makes a working control look like an outage — and hides a real outage
inside a busy afternoon.

## Resource observations

### Virtual threads
\`\`\`
$(cat "${RUN_DIR}"/virtual-rep1/jvm.txt 2>/dev/null || echo 'not collected')
\`\`\`

### Platform threads
\`\`\`
$(cat "${RUN_DIR}"/platform-rep1/jvm.txt 2>/dev/null || echo 'not collected')
\`\`\`

Container memory and JVM heap are **different numbers**. Heap, class metadata,
code cache, direct buffers, thread stacks and native allocations all live inside
the container limit — see [memory.md](../../docs/memory.md) before concluding a
pod needs more memory.

## Limitations (FR-106)

Every one of these is a reason a number above may not transfer.

1. **Workstation hardware.** One machine, shared with a browser, an IDE and
   whatever else was running. No isolation, no dedicated cores, no tuned kernel.
2. **The container runtime is a VM.** On macOS, Docker runs inside a Linux
   virtual machine with its own scheduler and its own memory ceiling. Every
   measurement passes through it.
3. **Synthetic workload shape.** Two endpoints in a fixed alternation. Real
   traffic has a mix, a diurnal shape, cache-hostile access patterns and
   payload sizes this does not reproduce.
4. **Concurrency is client-side and modest.** ${CONCURRENCY} concurrent clients
   is not the concurrency at which thread-model differences become interesting,
   and it may not saturate anything.
5. **Latency includes the whole path.** TLS termination, the Envoy hop, the
   Service translation and the JVM. It is not service time.
6. **Downstream behaviour is lab-shaped.** One Postgres, one Redis, both
   unloaded, both on the same machine, both with hostPath storage. No network
   latency, no contention, no replication lag.
7. **Resource limits are starting points, not measured settings** (FR-062). See
   [resource-tuning.md](../../docs/resource-tuning.md).
8. **THE AGENT'S OWN OVERHEAD IS IN EVERY NUMBER.** The OpenTelemetry Java agent
   is attached with \`OTEL_TRACES_SAMPLER=always_on\`, so every request is
   instrumented and exported. That is not free, and this benchmark does not
   measure an uninstrumented JVM. It measures a JVM that is being watched — which
   is what the lab runs, and is not what a production deployment with a sampling
   policy would run.
9. **Trace sampling is \`always_on\`**, a lab setting that exists so SC-012 is
   testable (FR-080b). It is not a production recommendation and it affects
   these figures.

## Conclusions

**None are drawn here, deliberately (FR-107).**

This report contains measurements, not findings. In particular it does **not**
claim:

- that one concurrency mode is faster than the other — the variance across
  repetitions must be smaller than the difference before that sentence is even
  available;
- **that virtual threads reduce memory consumption.** They do not inherently do
  so, and no measurement here would support the claim if they did. See
  [concurrency.md](../../docs/concurrency.md);
- that any figure predicts production behaviour on different hardware, under a
  different workload, at a different concurrency, with a different sampling
  policy.

What this report is good for: comparing two runs **of this lab** after a change
to this lab, on this machine, in the same session.
HEADER
} > "$OUT"

printf 'report: %s\n' "$OUT"
