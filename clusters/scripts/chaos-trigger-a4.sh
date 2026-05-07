#!/usr/bin/env bash
set -euo pipefail

# A4 Chaos Trigger — Kill virt-handler on Green when VMIM reaches Running
# Usage: bash clusters/scripts/chaos-trigger-a4.sh [poll_interval_sec]

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

log.banner "A4 Chaos Trigger — kill virt-handler (destination)"
log.info "  VM:        $VM_NAME"
log.verbose "  Source KC: $SOURCE_KC"
log.verbose "  Target KC: $TARGET_KC"
log.info "  Poll:      ${POLL}s"
log.info ""

step.begin "[1/4] WAIT FOR VMIM"
log.info "Waiting for VMIM to appear on source cluster..."
while true; do
  VMIM=$(oc --kubeconfig "$SOURCE_KC" get vmim -n "$NAMESPACE" \
    --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
    | grep "$VM_NAME" | head -1 || true)
  if [[ -n "$VMIM" && "$VMIM" != "" ]]; then
    log.info "VMIM found: $VMIM"
    step.end "PASS"
    break
  fi
  log.verbose "Polling for VMIM..."
  sleep "$POLL"
done

step.begin "[2/4] WAIT FOR RUNNING PHASE"
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
    Running)
      log.info "VMIM is Running — preparing chaos injection!"
      step.end "PASS"
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

step.begin "[3/4] RESOLVE TARGET NODE"

GREEN_NODE=""
GREEN_NODE=$(oc --kubeconfig "$TARGET_KC" get pods -n "$NAMESPACE" \
  -l "kubevirt.io/vm=$VM_NAME" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)

if [[ -z "$GREEN_NODE" ]]; then
  GREEN_NODE=$(oc --kubeconfig "$TARGET_KC" get vmi "$VM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
fi

if [[ -z "$GREEN_NODE" ]]; then
  GREEN_NODE=$(oc --kubeconfig "$TARGET_KC" get pods -n "$NAMESPACE" \
    -l "kubevirt.io=virt-launcher" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
fi

if [[ -z "$GREEN_NODE" ]]; then
  log.error "Could not find Green node for target VMI."
  log.info "  Listing virt-handler pods on Green for manual selection:"
  oc --kubeconfig "$TARGET_KC" get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide
  step.end "FAIL"
  exit 1
fi

log.info "Green node: $GREEN_NODE"
step.end "PASS"

step.begin "[4/4] FIRE CHAOS"
log.info "Target: virt-handler on $GREEN_NODE"

krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KC" \
  --namespace openshift-cnv \
  --pod-label 'kubevirt.io=virt-handler' \
  --node-label-selector "kubernetes.io/hostname=$GREEN_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 240

step.end "PASS"
log.success "Chaos injection complete."
