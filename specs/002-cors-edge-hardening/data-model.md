# Phase 1 Data Model: Browser Edge Hardening

**Feature**: `002-cors-edge-hardening` | **Date**: 2026-08-17

This feature persists nothing. Its "data model" is a **configuration model**: records bound from per-environment configuration, the validation rules that gate startup, and the state transitions of the application context. Constitution Principle IV (atomic distributed state mutations) does not apply — no Redis or database state is read or written.

---

## 1. `BrowserOriginProperties`

Owned by `browser-edge-starter`, bound to the existing key `hydra.cors`. Replaces the two per-service `CorsProperties` records, which are deleted.

| Component | Type | Source key | Default | Notes |
|---|---|---|---|---|
| `allowedOriginPatterns` | `List<String>` | `hydra.cors.allowed-origin-patterns` | `List.of()` | Origin *patterns*, never the literal `*`. Null → empty. Empty is legal (fails closed at request time). |
| `maxAge` | `Duration` | `hydra.cors.max-age` | `PT30M` | Preflight cache lifetime. Carried over unchanged from the current records. |

**Invariants**
- Null-safe and defensively copied in the compact constructor, matching the current records' behaviour.
- Every pattern MUST satisfy the controlled-domain rule in §3 or the context fails to refresh (FR-010).
- The literal `*` is never a valid value: it is illegal alongside credentialed requests, which the refresh flow requires.

**Migration note**: the key is unchanged, so no `application*.yml` or environment variable changes. What changes is which module binds it.

---

## 2. `ControlledDomainProperties`

Owned by `browser-edge-starter`, bound to the existing key `hydra.tenant`. Takes ownership of `baseDomains` from auth-service's `TenantResolutionProperties` (research R2).

| Component | Type | Source key | Default | Notes |
|---|---|---|---|---|
| `baseDomains` | `List<String>` | `hydra.tenant.base-domains` | `List.of()` | Trimmed, blank-filtered, lowercased with `Locale.ROOT`. Normalization moved verbatim from `TenantResolutionProperties`. |

**Invariants**
- No entry may be a public suffix (FR-018). Checked with Guava's `InternetDomainName.isPublicSuffix()`; see research R3 for why a label-count rule is not viable (`localhost` is a legitimate single-label base domain).
- All entries MUST share one registrable domain (FR-017, research R6). Two entries under different registrable domains make a silently-cross-site pairing reachable.
- Empty list remains legal and fails closed — tenant resolution already treats it that way, and this feature does not change that.

**Effect on `TenantResolutionProperties`**: loses its `baseDomains` component and keeps `reservedIdentifiers`. It consumes the shared record instead. Its normalization semantics move unchanged, since 003's tenant-resolution tests depend on them.

---

## 3. Controlled-domain rule

The single validation rule behind FR-010, evaluated per configured origin pattern at startup.

A pattern is **valid** when, after stripping scheme and any port:
1. Its host is either exactly a configured base domain, or a single-wildcard form covering exactly one label in front of one (`*.<base-domain>`), and
2. that base domain has itself passed the §2 invariants.

Anything else is **invalid** and is fatal at startup.

| Example | Base domains | Verdict |
|---|---|---|
| `http://*.localhost:5173` | `localhost` | Valid — the local development case in `application-local.yml` |
| `https://*.hydra.example.com` | `hydra.example.com` | Valid — the production case |
| `https://hydra.example.com` | `hydra.example.com` | Valid — exact match, no wildcard |
| `https://*.evil.com` | `hydra.example.com` | **Invalid** — not under a controlled domain |
| `https://*` | anything | **Invalid** — matches arbitrary domains |
| `https://*.com` | `com` | **Invalid** — rejected at the base domain by §2, before the pattern is examined |

The `com` row is the case FR-018 exists for: the pattern is well-formed *relative to its base domain*, so only checking patterns against the list would let one configuration error authorize an arbitrarily broad origin.

---

## 4. Startup state transitions

The application context has three terminal outcomes. This is the whole behavioural contract of the validation work.

| Condition | Outcome | Requirement |
|---|---|---|
| Patterns valid, one registrable domain, no public-suffix base domain | **Context refreshes.** Policy active; log names the patterns at `INFO`. | — |
| `allowedOriginPatterns` empty | **Context refreshes**, `WARN` logged. Every cross-origin request is then rejected at request time. | FR-002 |
| Any pattern outside the controlled-domain set | **Refresh fails.** Exception names the offending pattern and the reason. | FR-010 |
| Any base domain is a public suffix | **Refresh fails.** Exception names the offending base domain. | FR-018 |
| Base domains span multiple registrable domains | **Refresh fails.** Exception names the conflicting domains. | FR-017 |

**The asymmetry in rows 2 and 3 is deliberate** and must survive implementation: an empty list is *safe but useless*, so it warns; an over-broad pattern is *unsafe*, so it is fatal. Collapsing both into "fatal" would break any deployment that legitimately serves no browser traffic. Collapsing both into "warn" would reintroduce the credential-echo hazard FR-010 exists to close.

---

## 5. Transparent-edge conformance verdict

Not a persisted entity — the result the conformance suite produces. Modelled here because it is the contract's observable output.

| Field | Meaning | Requirement |
|---|---|---|
| Host preserved | The host auth-service observed equals the host the client addressed, byte for byte | FR-011, FR-012 |
| Header count | Exactly one set of cross-origin response headers reached the client | FR-003, FR-015 |
| Header origin | Those headers were emitted by the service, not the edge | FR-003 |
| Preflight unauthenticated | The `OPTIONS` preflight succeeded without credentials | FR-005 |
| Echoed origin | The response named the single requesting origin, never a literal wildcard | FR-009 |

The suite runs against a base URL and asserts all five. Details of how each is probed belong to [contracts/transparent-edge-contract.md](contracts/transparent-edge-contract.md).

---

## 6. Entity relationships

```text
ControlledDomainProperties  ──validates──▶  BrowserOriginProperties
   (hydra.tenant.base-domains)                (hydra.cors.allowed-origin-patterns)
        │                                              │
        │ consumed by                                  │ builds
        ▼                                              ▼
TenantResolutionProperties                      CorsConfigurationSource
   (auth-service, keeps reservedIdentifiers)       (bean type + name unchanged,
                                                    so SecurityCommons is untouched)
```

The left edge is the point of this design: tenant resolution and the origin policy read **one** list from **one** owner, so the drift that FR-001 exists to prevent is structurally impossible rather than merely discouraged.
