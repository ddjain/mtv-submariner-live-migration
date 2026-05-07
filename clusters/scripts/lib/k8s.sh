#!/usr/bin/env bash
# clusters/scripts/lib/k8s.sh — Shared Kubernetes helpers.
#
# Requires lib/log.sh to be sourced first.

[[ -n "${_K8S_SH_LOADED:-}" ]] && return 0
_K8S_SH_LOADED=1

# ── capture_pod_restarts ──────────────────────────────────────
# Returns a JSON array of {namespace, pod, restarts} for pods
# in the given namespaces.
#
# CRITICAL: This function's stdout is captured into variables
# and parsed by jq. It must NEVER emit logging or ANSI to
# stdout. Diagnostics go to log.debug_err (stderr).
#
# Usage:
#   RESTARTS=$(capture_pod_restarts "$KUBECONFIG_PATH" ns1 ns2 ...)
capture_pod_restarts() {
  local kc="$1"; shift
  local result="[]"
  for ns in "$@"; do
    log.debug_err "capture_pod_restarts: scanning namespace $ns"
    local pods_json
    pods_json="$(KUBECONFIG="$kc" kubectl get pods -n "$ns" -o json 2>/dev/null \
      || echo '{"items":[]}')"
    local ns_restarts
    ns_restarts="$(echo "$pods_json" | jq --arg ns "$ns" \
      '[.items[] | {namespace: $ns, pod: .metadata.name, restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)}]')"
    result="$(echo "$result" "$ns_restarts" | jq -s 'add')"
  done
  echo "$result"
}
