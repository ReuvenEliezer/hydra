# ---------------------------------------------------------------------------
# k8s-lab — the single developer entry point (FR-089).
#
# Every operation the lab exposes is a target here, every target delegates to a
# script under scripts/, and every target that checks anything exits non-zero
# when a required check fails (FR-098). No target hard-codes a version; scripts
# read versions.env (SC-022). `make help` lists the full surface.
# ---------------------------------------------------------------------------

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
LAB_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
S := $(LAB_ROOT)/scripts
T := $(LAB_ROOT)/tests

.DEFAULT_GOAL := help

.PHONY: help \
        doctor setup setup-reduced cleanup verify-versions \
        cluster-create cluster-delete cluster-recreate cluster-status cluster-health \
        registry-create registry-status \
        net-status net-test \
        gw-status gw-test \
        platform-install platform-status \
        image-build image-build-clean image-publish \
        app-build app-deploy app-status \
        test test-smoke test-integration test-failure test-pod-failure test-netpol \
        test-scaling test-rolling-update test-edge-conformance test-hostile-edge \
        test-xff-forgery test-new-tenant test-host-preservation test-edge-headers \
        test-trace test-gitops test-rate-limit-metrics verify-targets \
        validate validate-full validate-repro \
        load-test bench \
        dump logs debug \
        console-cluster console-metrics console-delivery argocd-status

# --- Diagnostics and setup -------------------------------------------------

## doctor: report whether this host can run the lab. Installs nothing (FR-003)
doctor:
	@$(S)/doctor.sh

## setup: run every checkpoint in order, halting at the first failure (FR-014)
setup:
	@$(S)/setup.sh

## setup-reduced: setup with values-reduced.yaml, naming what it disables (FR-091)
setup-reduced:
	@$(S)/setup.sh --reduced

## cleanup: remove the cluster, the registry and lab-created local state (FR-109)
cleanup:
	@$(S)/cleanup.sh

## verify-versions: assert every version resolves to versions.env (SC-022)
verify-versions:
	@$(S)/verify-versions.sh

# --- Cluster ---------------------------------------------------------------

## cluster-create: 1 control-plane + N workers, every node verified Ready (FR-013)
cluster-create:
	@$(S)/cluster.sh create

## cluster-delete: delete the lab cluster
cluster-delete:
	@$(S)/cluster.sh delete

## cluster-recreate: delete then create
cluster-recreate:
	@$(S)/cluster.sh recreate

## cluster-status: what exists
cluster-status:
	@$(S)/cluster.sh status

## cluster-health: whether it works
cluster-health:
	@$(S)/cluster.sh health

# --- Registry --------------------------------------------------------------

## registry-create: local registry wired into the cluster (FR-016, FR-019)
registry-create:
	@$(S)/registry.sh create

## registry-status: prove by an executed pull that the cluster can reach it
registry-status:
	@$(S)/registry.sh status

# --- Networking ------------------------------------------------------------

## net-status: Cilium health on every node
net-status:
	@$(S)/platform.sh net-status

## net-test: real pod-to-pod and pod-to-service traffic (FR-024)
net-test:
	@$(T)/smoke/net-test.sh

# --- Gateway ---------------------------------------------------------------

## gw-status: GatewayClass exists, Gateway Programmed, routes Accepted (FR-034)
gw-status:
	@$(S)/platform.sh gw-status

## gw-test: a workstation request answered from inside the cluster (FR-034)
gw-test:
	@$(T)/smoke/gw-test.sh

# --- Platform --------------------------------------------------------------

## platform-install: Cilium, Gateway API, certs, observability, Argo CD, console
platform-install:
	@$(S)/platform.sh install

## platform-status: per-component platform status
platform-status:
	@$(S)/platform.sh status

# --- Images ----------------------------------------------------------------

## image-build: build both service images, printing the toolchain (FR-004, FR-017)
image-build:
	@$(S)/images.sh build

## image-build-clean: --no-cache from a clean state — the FR-018 verification
image-build-clean:
	@$(S)/images.sh build-clean

## image-publish: publish to the lab registry (FR-021)
image-publish:
	@$(S)/images.sh publish

# --- Applications ----------------------------------------------------------

## app-build: build and publish both service images
app-build: image-build image-publish

## app-deploy: migration Job -> fixture Job -> Deployments (FR-052, FR-052a)
app-deploy:
	@$(S)/app.sh deploy

## app-status: per-workload readiness, replica and restart counts
app-status:
	@$(S)/app.sh status

# --- Testing ---------------------------------------------------------------

## test: smoke + integration + edge conformance + failure. Never recreates (FR-099)
test:
	@$(S)/test.sh

## test-smoke: every FR-094 check
test-smoke:
	@$(T)/smoke/run.sh

## test-integration: sign in -> create order -> list orders via the gateway (FR-095)
test-integration:
	@$(T)/integration/run.sh

## test-failure: all nine drills, each with a verified restore (FR-097)
test-failure:
	@$(T)/failure/run.sh all

## test-pod-failure: the pod-delete drill alone (FR-093)
test-pod-failure:
	@$(T)/failure/run.sh pod-delete

## test-netpol: the network-policy drill alone (FR-093, SC-013)
test-netpol:
	@$(T)/failure/run.sh network-policy

## test-rolling-update: the rolling-update drill alone (SC-009)
test-rolling-update:
	@$(T)/failure/run.sh rolling-update

## test-scaling: replica count responds to real observed metrics (SC-016)
test-scaling:
	@$(T)/perf/scaling.sh

## test-edge-conformance: Hydra's existing suite against the lab gateway (FR-096)
test-edge-conformance:
	@$(S)/edge-conformance.sh lab

## test-hostile-edge: the same suite must FAIL, naming the clause (FR-042)
test-hostile-edge:
	@$(S)/edge-conformance.sh hostile

# --- Individually runnable edge and observability checks --------------------
# These are the named scenarios the quickstart walks through. They are separate
# targets rather than steps inside `make test` because each one answers a
# specific success criterion, and being able to run exactly one of them is what
# makes a failure diagnosable.

## test-xff-forgery: a forged X-Forwarded-For is not honoured (FR-041, SC-006)
test-xff-forgery:
	@$(T)/integration/xff-forgery.sh

## test-new-tenant: a tenant added now works with zero gateway changes (SC-007)
test-new-tenant:
	@$(T)/integration/new-tenant.sh

## test-host-preservation: Host survives TLS termination end to end (FR-036)
test-host-preservation:
	@$(T)/integration/host-preservation.sh

## test-edge-headers: the gateway emits no CORS of its own (FR-037)
test-edge-headers:
	@$(T)/integration/edge-headers.sh

## test-trace: one request, one connected trace, within 30s (SC-012)
test-trace:
	@$(T)/integration/trace-e2e.sh

## test-rate-limit-metrics: 429s are separable from errors (FR-079)
test-rate-limit-metrics:
	@$(T)/integration/rate-limit-metrics.sh

## test-gitops: a tracked change converges with no deploy command (FR-083)
test-gitops:
	@$(T)/integration/gitops-converge.sh

## verify-targets: every documented target exists and works (SC-019)
verify-targets:
	@$(S)/verify-targets.sh

## validate: aggregate per-component verdicts plus one overall verdict (FR-101)
validate:
	@$(S)/validate.sh

## validate-full: destroy -> recreate -> install -> deploy -> verify (FR-100)
validate-full:
	@$(S)/validate.sh --full

## validate-repro: validate-full 3x consecutively, unattended, recorded (SC-003)
validate-repro:
	@$(S)/reproducibility.sh

# --- Performance -----------------------------------------------------------

## load-test: drive traffic through the actual gateway (FR-071)
load-test:
	@$(T)/perf/load-test.sh

## bench: both concurrency modes, GC held constant, full report (FR-103..107)
bench:
	@$(T)/perf/bench.sh

# --- Inspection ------------------------------------------------------------

## dump: everything needed to name a failing component without more commands
dump:
	@$(S)/dump.sh

## logs: structured logs for a named workload — make logs WORKLOAD=auth-service
logs:
	@$(S)/consoles.sh logs

## debug: guided diagnosis entry point
debug:
	@$(S)/debug.sh

## console-cluster: Headlamp (FR-087, FR-088)
console-cluster:
	@$(S)/consoles.sh cluster

## console-metrics: Grafana — metrics and traces, no fourth console (FR-088)
console-metrics:
	@$(S)/consoles.sh metrics

## console-delivery: Argo CD (FR-088)
console-delivery:
	@$(S)/consoles.sh delivery

## argocd-status: per-Application sync and health, read from the resources (FR-086)
argocd-status:
	@$(S)/consoles.sh argocd-status

# --- Help ------------------------------------------------------------------

help:
	@echo "k8s-lab — Hydra's Kubernetes production lab"
	@echo ""
	@echo "Usage: make <target>    (run from k8s-lab/)"
	@echo ""
	@grep -hE '^## [a-z-]+:' $(MAKEFILE_LIST) \
	  | sed -e 's/^## //' \
	  | awk -F': ' '{ printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 }'
	@echo ""
	@echo "Start with: make doctor"
