# Contract: `browser-edge-starter` module

**Feature**: `002-cors-edge-hardening` | **Date**: 2026-08-17

The public surface a consuming service depends on. Modelled on `rate-limit-starter`, whose onboarding contract is "depend on the module, supply configuration, nothing here changes."

---

## 1. Onboarding a service

```xml
<dependency>
    <groupId>com.reuven</groupId>
    <artifactId>browser-edge-starter</artifactId>
    <version>${project.version}</version>
</dependency>
```

That is the whole integration. Auto-configuration is discovered through `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`, so **no** `@ComponentScan`, `@EnableConfigurationProperties`, or `@Import` is added to any service. This mirrors `RateLimitAutoConfiguration`, which is discovered the same way.

A service that supplies no `hydra.cors` configuration gets an empty pattern list, a startup warning, and cross-origin requests rejected at request time. Onboarding is additive and cannot break a service that does not serve browsers.

---

## 2. Configuration keys

Both keys already exist in this repository and are **unchanged** by this feature. Only the module that binds them changes.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `hydra.cors.allowed-origin-patterns` | list of string | empty | Browser origin patterns. Empty fails closed. |
| `hydra.cors.max-age` | duration | `PT30M` | Preflight cache lifetime. |
| `hydra.tenant.base-domains` | list of string | empty | The controlled domain set. Also consumed by auth-service tenant resolution. |

Existing values continue to work untouched:

```yaml
# auth-service/src/main/resources/application-local.yml — unchanged by this feature
hydra:
  cors:
    allowed-origin-patterns: http://*.localhost:5173,http://*.localhost:6006
  tenant:
    base-domains: localhost
```

---

## 3. Beans contributed

| Bean | Type | Notes |
|---|---|---|
| `corsConfigurationSource` | `CorsConfigurationSource` | Same type **and same bean name** as the beans it replaces, so `http.cors(Customizer.withDefaults())` in `SecurityCommons` resolves it by type with no change. |
| `browserOriginProperties` | `BrowserOriginProperties` | Registered by the auto-configuration, not by a scan. |
| `controlledDomainProperties` | `ControlledDomainProperties` | Consumed by auth-service's tenant resolution as well as by origin-policy validation. |

**Policy the source applies** — carried over verbatim from the current `CorsConfig` in both services, because each element is load-bearing and documented as such in the existing Javadoc:

| Setting | Value | Why it cannot be "tidied up" |
|---|---|---|
| Allowed origin patterns | from configuration | Patterns, not literals — every tenant is its own origin. |
| Allowed methods | `GET`, `POST`, `OPTIONS` | Unchanged. |
| Allowed headers | `Authorization`, `Content-Type`, `Accept` | `X-Tenant-ID` stays removed — 003 deleted it, and re-adding it would advertise a parameter the server no longer reads. |
| Exposed headers | `Retry-After` | Not CORS-safelisted. Without it the client reads `null` cross-origin and cannot show a rate-limit countdown. |
| Allow credentials | `true` | Without it the browser will not attach the refresh cookie, and every session dies at access-token expiry. |
| Max age | from configuration | — |

---

## 4. Startup failure modes

Each throws from the bean factory method, failing context refresh before the service binds its port. The message MUST name the offending value.

| Condition | Message must name | Requirement |
|---|---|---|
| Origin pattern outside the controlled domain set | The pattern, and the base domains it was checked against | FR-010 |
| Base domain that is itself a public suffix | The base domain | FR-018 |
| Base domains spanning multiple registrable domains | Every conflicting domain | FR-017 |

Empty `allowedOriginPatterns` is **not** a failure — it warns and starts. See data-model.md §4 for why that asymmetry is intentional.

---

## 5. What each consuming service deletes

| Service | Deleted |
|---|---|
| auth-service | `config/CorsProperties.java`, `config/CorsConfig.java`; `baseDomains` component of `config/TenantResolutionProperties.java` |
| order-service | `config/CorsProperties.java`, `config/CorsConfig.java` |

Deletion is the point, not a side effect. Leaving either local record in place would let a service bind `hydra.cors` twice with different semantics — the drift FR-001 exists to remove.

---

## 6. What is explicitly unchanged

Stated so a reviewer can bound the diff:

- `SecurityCommons.applyCommonSecurity` — still `http.cors(Customizer.withDefaults())`; the bean is resolved by type.
- `SecurityCommons.authRules` — the `OPTIONS /**` permit-all backstop stays exactly as written, including its comment. It already satisfies FR-005.
- `CookieUtil` — untouched. `SameSite=Strict`, `httpOnly`, path `/api/v1/auth`, host-only.
- CSRF — remains disabled in both services.
- order-service tenant handling — still derived from the JWT claim.
