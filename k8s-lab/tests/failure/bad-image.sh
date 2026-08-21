#!/usr/bin/env bash
# bad-image drill (FR-097).
#
# Expected observable: ImagePullBackOff on the new pod, AND the previously
# healthy pods keep serving. The second half is what makes this a resilience
# drill rather than a demonstration that Kubernetes reports errors — with
# maxUnavailable: 0, a broken image must not be able to take down what is
# already running.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

TARGET_DEPLOY="${1:-order-service}"

drill_begin "bad-image (${TARGET_DEPLOY})" \
  "ImagePullBackOff appears; healthy pods keep serving; restore recovers" || { log_summary; exit 1; }

original="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
[[ -n "$original" ]] || { log_fail "could not read the current image"; log_summary; exit 1; }
log_info "current image: ${original}"

bad="${LAB_REGISTRY_HOST_ADDR}/hydra/${TARGET_DEPLOY}:definitely-does-not-exist"
$K -n "${NS_APP}" set image "deploy/${TARGET_DEPLOY}" "${TARGET_DEPLOY}=${bad}" >/dev/null 2>&1
log_pass "trigger: image set to a non-existent tag" "${bad}"

if wait_for "ImagePullBackOff or ErrImagePull appears" 180 \
     bash -c "$K -n ${NS_APP} get pods -l app.kubernetes.io/name=${TARGET_DEPLOY} -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{\"\n\"}{end}{end}' 2>/dev/null | grep -qE 'ImagePullBackOff|ErrImagePull'"; then
  log_pass "the failure is observable as ImagePullBackOff" "kubectl get pods"
else
  log_fail "no ImagePullBackOff appeared"
fi

# The healthy pods must still be serving. This is the assertion that matters.
code="$(curl_status "${LAB_BASE_URL}/api/v1/tenant")"
assert_eq "the gateway still serves while a rollout is failing" "200" "$code"

healthy="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
assert_ge "previously healthy replicas keep running" "${healthy:-0}" "1"
log_info "maxUnavailable: 0 is what makes that true — the old pods are not torn down for a new one that never becomes Ready."

drill_restore "restore the original image" \
  $K -n "${NS_APP}" set image "deploy/${TARGET_DEPLOY}" "${TARGET_DEPLOY}=${original}"
drill_end
