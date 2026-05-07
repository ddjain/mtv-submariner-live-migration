#!/usr/bin/env bash
set -euo pipefail

# A5 Chaos Trigger — Kill virt-controller on Green when VMIM appears (early phase)
# Usage: bash clusters/scripts/chaos-trigger-a5.sh <vm-name> [poll_interval_sec]

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

SOURCE_KC="${REPO_ROOT}/clusters/source-cluster/auth/kubeconfig"
TARGET_KC="${REPO_ROOT}/clusters/target-cluster/auth/kubeconfig"
VM_NAME="${1:-}"
NAMESPACE="default"
POLL="${2:-2}"

if [[ -z "$VM_NAME" ]]; then
  echo "Usage: $0 <vm-name> [poll_interval_sec]"
  echo "  e.g.: $0 brave-storm-vm 2"
  exit 1
fi

log.banner "A5 Chaos Trigger — kill virt-controller (Green)"
log.info "  VM:        $VM_NAME"
log.verbose "  Source KC: $SOURCE_KC"
log.verbose "  Target KC: $TARGET_KC"
log.info "  Poll:      ${POLL}s"
log.info ""

step.begin "[1/3] WAIT FOR VMIM"
log.info "Waiting for VMIM (vmiName=$VM_NAME) on source cluster..."
while true; do
  VMIM=$(oc --kubeconfig "$SOURCE_KC" get vmim -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r ".items[] | select(.spec.vmiName == \"$VM_NAME\") | .metadata.name" \
    | head -1 || true)
  if [[ -n "$VMIM" && "$VMIM" != "" ]]; then
    log.info "VMIM found: $VMIM (vmiName=$VM_NAME)"
    step.end "PASS"
    break
  fi
  log.verbose "Polling for VMIM..."
  sleep "$POLL"
done

step.begin "[2/3] WAIT FOR EARLY PHASE"
LAST_PHASE=""
while true; do
  PHASE=$(oc --kubeconfig "$SOURCE_KC" get vmim "$VMIM" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

  if [[ "$PHASE" != "$LAST_PHASE" ]]; then
    log.info "VMIM $VMIM -> phase: $PHASE"
    LAST_PHASE="$PHASE"
  else
    log.verbose "VMIM $VMIM -> phase: $PHASE"
  fi

  case "$PHASE" in
    Pending|Scheduling|Scheduled|Synchronizing|PreparingTarget)
      log.info "VMIM in early phase ($PHASE) — firing chaos NOW!"
      step.end "PASS"
      break
      ;;
    Running)
      log.warn "VMIM already Running — firing chaos (slightly late but still valid)!"
      step.end "WARN"
      break
      ;;
    Succeeded|Failed)
      log.error "VMIM already terminal ($PHASE). Too late."
      step.end "FAIL"
      exit 1
      ;;
  esac
  sleep "$POLL"
done

step.begin "[3/3] FIRE CHAOS"
log.info "Target: virt-controller (Deployment) in openshift-cnv"

krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KC" \
  --namespace openshift-cnv \
  --pod-label 'kubevirt.io=virt-controller' \
  --disruption-count 1 \
  --kill-timeout 180 \
  --expected-recovery-time 120

step.end "PASS"
log.success "Chaos injection complete."
