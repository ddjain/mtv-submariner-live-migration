#!/usr/bin/env bash
#
# Force-clean all VM resources (VMs, VMIs, DataVolumes) from a cluster.
# Handles stuck Terminating resources by stripping finalizers first.
#
# Usage: force-clean-vms.sh <kubeconfig> <namespace>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

KC="${1:?Usage: force-clean-vms.sh <kubeconfig> <namespace>}"
NS="${2:?Usage: force-clean-vms.sh <kubeconfig> <namespace>}"
TIMEOUT=30

_oc() { oc --kubeconfig "$KC" "$@"; }

strip_finalizers_and_delete() {
  local resource_type="$1"
  local items

  items=$(_oc get "$resource_type" -n "$NS" -o name 2>/dev/null) || true
  if [ -z "$items" ]; then
    log.verbose "No $resource_type found."
    return
  fi

  for item in $items; do
    local short_name="${item##*/}"
    log.verbose "Removing finalizers from $resource_type/$short_name ..."
    _oc patch "$item" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done

  log.verbose "Force-deleting all $resource_type ..."
  _oc delete "$resource_type" --all -n "$NS" --force --grace-period=0 --ignore-not-found 2>/dev/null || true
}

wait_for_gone() {
  local resource_type="$1"
  local elapsed=0

  while [ "$elapsed" -lt "$TIMEOUT" ]; do
    local remaining
    remaining=$(_oc get "$resource_type" -n "$NS" --no-headers 2>/dev/null | wc -l) || remaining=0
    if [ "$remaining" -eq 0 ]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  local leftover
  leftover=$(_oc get "$resource_type" -n "$NS" --no-headers 2>/dev/null) || true
  if [ -n "$leftover" ]; then
    log.warn "$resource_type still present after ${TIMEOUT}s — may need manual intervention:"
    log.info "$leftover"
  fi
}

task.begin "Cleaning VirtualMachines"
strip_finalizers_and_delete vm
wait_for_gone vm
task.pass "VMs cleaned"

task.begin "Cleaning VirtualMachineInstances"
strip_finalizers_and_delete vmi
wait_for_gone vmi
task.pass "VMIs cleaned"

task.begin "Cleaning DataVolumes"
_oc delete dv --all -n "$NS" --ignore-not-found 2>/dev/null || true
wait_for_gone dv
task.pass "DVs cleaned"

log.success "Cluster cleanup complete."
