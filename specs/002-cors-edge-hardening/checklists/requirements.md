# Specification Quality Checklist: Browser Edge Hardening

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-13
**Last Updated**: 2026-08-17
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Requirement → Acceptance Scenario Coverage

| Requirement | Covered by |
|-------------|------------|
| FR-001 | US1 scenarios 1, 2 |
| FR-002 | US1 scenario 3 |
| FR-003 | US2 scenarios 1, 2, 3 |
| FR-004 | US1 scenario 1 |
| FR-005 | US2 scenario 6 |
| FR-006 | US4 scenarios 1, 3 |
| FR-007 | US4 scenario 4 |
| FR-008 | US2 scenario 5 |
| FR-009 | US2 scenario 7 |
| FR-010 | US1 scenario 5 |
| FR-011 | US3 scenarios 1, 2 |
| FR-012 | US3 scenario 3 |
| FR-013 | US3 scenario 4, SC-007 |
| FR-014 | US4 scenario 5 |
| FR-015 | US2 scenario 4 |
| FR-016 | US3 scenario 5, SC-010 |
| FR-017 | US4 scenario 2 |
| FR-018 | US1 scenario 6 |

## Notes

### Post-clarification re-validation (2026-08-17)

Five clarifications were accepted and integrated. All 16 checkboxes were passing before and remain passing — no newly-checked items, no regressions. The spec grew from 15 FRs to 18 and from 10 SCs to 12; the coverage table above is updated accordingly.

Sections rewritten because the answers invalidated them, rather than merely extended:

- **User Story 2** retitled and rewritten. Two scenarios posited a gateway that enforces the policy; ownership is now decided against that, so they were replaced rather than amended.
- **User Story 4** retitled and rewritten. Its "either succeeds or fails explicitly" framing was the undecided form of a question now answered — cross-site is declined.
- **Edge Cases** lost the migration-window entry. Under services-always-own there is no window in which both legitimately emit, so sequencing through one is not a scenario that exists.
- **Out of Scope** gained edge-technology selection. This is the notable second-order effect: choosing a transparent edge removed the Kubernetes-versus-docker-compose dependency entirely, so the feature no longer blocks on a decision the constitution says is still under evaluation.

### Validation iteration 2 (2026-08-17)

The first pass marked all items complete immediately after drafting, without re-reading the file. A second pass against the written text found three defects, all now fixed:

1. **Functional requirements were not in numeric order.** Grouping them under three concern subheadings pushed FR-006 and FR-007 below FR-013, so the list read 001–005, 008–010, 011–013, 006–007, 014. Fixed by flattening to a single ascending list with an inline `[policy]` / `[host]` / `[credential]` tag on each requirement — this keeps the concern grouping legible without scrambling the numbers, and preserves every existing FR number.
2. **FR-005 had no acceptance scenario.** Preflight-without-authentication was covered only by an Edge Case, which is a prompt for design thinking, not a testable criterion. Added as US2 scenario 6.
3. Stray double space in the Context section.

Claims in the Context section were re-verified against source in this pass, including "no gateway in any committed environment" — confirmed: `docker-compose.yml` defines only PostgreSQL and Redis, `docker-compose.test.yml` only a test PostgreSQL, and the repository contains no committed proxy, ingress, or gateway configuration of any kind.

### On the "no implementation details" items

Both items pass for the mandatory sections — User Scenarios, Requirements, Success Criteria, Assumptions, and Out of Scope are written in protocol and behavior vocabulary (origin policy, preflight, `Host`, credential) with no language, framework, or library named.

Concrete configuration keys, method names, and infrastructure names appear **only** in the non-template `Context` section. That is deliberate: constitution Principle V (Audit Before Building) requires the current state to be confirmed against source rather than taken from prior docs, and recording what was actually found is the point of that section. It is evidence, not design.

### Revision history

- **2026-08-13** — Initial spec, split out of the `001-hydra-ui-package` design review. Three open questions: single-source ownership, edge-vs-service enforcement, cookie topology.
- **2026-08-17** — Re-audited against source after `003-tenant-url-resolution` shipped. Changes:
  - **Scope grew by one story.** 003 made tenant identity a function of the request's `Host` and explicitly levied end-to-end host preservation on this feature. That is now User Story 3 (P1) and FR-011 – FR-013.
  - **Context corrected.** The prior revision attributed the open edge-layer question to the README's roadmap; the README has no such section. The authoritative statement is the constitution's Technology Constraints. Corrected in place.
  - **Context refreshed.** The policy is no longer a fixed origin list — 003 moved both services to origin *patterns* and renamed the property key. The duplication in User Story 1 is now demonstrated rather than predicted: 003 had to apply the identical change twice, by hand, across both services.
  - **Tenant isolation added.** Per-tenant subdomains created a new way to break the renewal credential — broadening its scope to span sibling tenant hosts would leak one tenant's credential to another. FR-014 and SC-008 close that.
  - New requirements: FR-009 – FR-014. New success criteria: SC-006 – SC-009. Original FR-001 – FR-008 and SC-001 – SC-005 retain their numbers so existing cross-references stay valid.

### Before `/speckit-plan`

- `.specify/feature.json` points at `specs/002-cors-edge-hardening`. Note that `specs/004-hydra-ui-redesign` has 4 open tasks; repoint before resuming it.
- **`/speckit-clarify` is complete** (5 of 5 questions, session 2026-08-17). The blocking ambiguity it was needed for — policy ownership — is resolved, and resolving it dissolved the edge-technology dependency rather than requiring it to be answered.
- One consequence needs planning attention: FR-010 derives the controlled-domain set from the declared tenant base domains, but that configuration exists only in auth-service today (introduced by `003-tenant-url-resolution`). order-service has no equivalent. Making the derivation available to every browser-facing service is a design question for `/speckit-plan`, and is recorded in the spec's Assumptions rather than assumed away.
