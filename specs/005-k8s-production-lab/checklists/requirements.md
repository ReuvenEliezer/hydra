# Specification Quality Checklist: Kubernetes Production Lab

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-18
**Updated**: 2026-08-18 — revised after the requester directed the lab to run Hydra's real
`auth-service` and `order-service` rather than purpose-built demonstration services
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

## Constitution Alignment

- [x] **Principle I (framework-free shared core)** — untouched. No module changes to `infra-shared`.
- [x] **Principle II (dedicated modules)** — untouched. FR-044 forbids new modules for the services;
      the lab's own assets live outside the reactor.
- [x] **Principle III (load-path-authoritative paths)** — respected. FR-018 requires the container
      build to cover every module a service depends on, which is the same class of silent,
      compile-clean, runtime-only breakage the principle exists to prevent.
- [x] **Principle IV (atomic distributed state, NON-NEGOTIABLE)** — FR-067 and SC-010 make this
      observable for the first time. The principle exists because Hydra is multi-instance; until
      this feature, that has been an argument rather than a measurement.
- [x] **Principle V (audit before building)** — the open edge-layer question is surfaced rather than
      assumed away: FR-113 requires a written finding framed as evidence, and the *Scope boundaries*
      section states explicitly that a local cluster cannot close the question by itself.

## Validation Notes

**Product names**: The requirements input mandates specific products. Those are input constraints,
not downstream choices, so they are recorded once in *Assumptions → Mandated constraints* and every
functional requirement is written in role-neutral terms ("the networking layer", "the delivery
controller", "the relational datastore"). A scan confirms no product names appear in the user
stories, functional requirements or success criteria. Hydra's own service names are used
deliberately — they are the subject of the feature, not an implementation detail.

**Audience**: The stakeholder is a platform engineer; the deliverable *is* infrastructure knowledge.
The spec is readable without opening a manifest, but assumes the reader knows what a cluster, a pod
and a service are. That is the correct floor for this audience.

**What changed in this revision**: Running Hydra's real services rather than stand-ins added five
requirement areas that did not previously exist and could not have — *Transparent edge conformance*
(FR-035 to FR-042), *Backing services and state* (FR-051 to FR-056), *Multi-instance state
correctness* (FR-067 to FR-069), the forwarded-address security boundary (FR-041, SC-006), and the
edge finding (FR-113). It also removed the earlier exclusion of stateful workloads, which is no
longer tenable: these services require a real datastore and a real cache.

**Measurability of a learning outcome**: SC-021 (an unfamiliar engineer can set up, break, diagnose
and recover from documentation alone) is deliberately a human-subject criterion. It is verifiable by
observation and reflects the feature's purpose more directly than any proxy metric would.

**Honesty requirements are first-class**: FR-042, FR-098, FR-107, FR-116, SC-015 and SC-017 exist
because the largest failure mode for a feature of this shape is reporting components as working when
they were never executed. FR-042 is the sharpest of these — a conformance suite that passes against
a deliberately hostile gateway is proving nothing, so the hostile case is a required artifact.

## Verified Repository Conditions

Confirmed against source while writing this spec — recorded because planning depends on them:

- [x] Both service container builds copy only five of the root build's seven modules. The most
      recently added shared module and the cross-service test module are absent from both, and the
      build files were last modified before either was introduced. A container build from clean is
      expected to fail at reactor load. **Pre-existing, not introduced by this feature**; FR-018
      requires it fixed before US2 can pass.
- [x] Both service images pin explicit garbage-collector flags, at least one of which is obsolete on
      the mandated Java version. FR-059 removes the inert flag; FR-059a measures the collector choice
      and recommends, leaving the change itself to separate work.
- [x] Client-address resolution trusts the left-most forwarded-address value, with documentation
      that explicitly assumes the edge overwrites it. FR-041 converts that assumption into an
      enforced, tested property of the lab gateway.
- [x] The renewal credential requires a secure transport by default, which is why FR-032 requires
      TLS termination at the gateway rather than treating it as optional.
- [x] Tenant resolution fails closed universally when its base-domain configuration is empty, so the
      lab must populate it deliberately.

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`
- Validation run: 1 iteration on the revised spec, all items passing
- 124 functional requirements, 23 success criteria, 8 prioritized user stories, 5 clarifications resolved (session 2026-08-18)
