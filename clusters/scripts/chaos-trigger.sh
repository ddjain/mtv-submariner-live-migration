#!/usr/bin/env bash
set -euo pipefail

# Universal chaos trigger for CCLM scenarios targeting destination virt-handler.
# Auto-detects VM name, VMIM, and Green node. No manual substitution needed.
#
# Usage:
#   bash clusters/scripts/chaos-trigger.sh                    # auto-detect everything
#   bash clusters/scripts/chaos-trigger.sh my-vm-name         # optional: specify VM name
#   bash clusters/scripts/chaos-trigger.sh my-vm-name 1       # optional: poll interval (default 2s)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

SKC="${REPO_ROOT}/clusters/source-cluster/auth/kubeconfig"
TKC="${REPO_ROOT}/clusters/target-cluster/auth/kubeconfig"
VM_NAME="${1:-}"
POLL="${2:-2}"

log.banner "CCLM Chaos Trigger — kill virt-handler (destination)"
log.info "  VM:   ${VM_NAME:-AUTO-DETECT}"
log.info "  Poll: ${POLL}s"
log.info ""

# ── Step 1: Detect VM name if not provided ──────────────────
if [[ -z "$VM_NAME" ]]; then
  step.begin "[1/3] DETECT VM"
  log.info "Watching for new VMIM on source cluster..."
  while true; do
    VMIM_LINE=$(oc --kubeconfig "$SKC" get vmim -n default --no-headers \
      -o custom-columns='NAME:.metadata.name,VMI:.spec.vmiName' 2>/dev/null | tail -1 || true)
    if [[ -n "$VMIM_LINE" && "$VMIM_LINE" != *"No resources"* ]]; then
      VM_NAME=$(echo "$VMIM_LINE" | awk '{print $2}')
      if [[ -z "$VM_NAME" || "$VM_NAME" == "<none>" ]]; then
        VM_NAME=$(echo "$VMIM_LINE" | awk '{print $1}')
      fi
      log.info "Detected VMIM: $VMIM_LINE"
      log.info "Using VM name: $VM_NAME"
      break
    fi
    LAUNCHER=$(oc --kubeconfig "$TKC" get pods -n default -l kubevirt.io=virt-launcher \
      --no-headers -o custom-columns='VM:.metadata.labels.kubevirt\.io/vm' 2>/dev/null | tail -1 || true)
    if [[ -n "$LAUNCHER" && "$LAUNCHER" != *"No resources"* && "$LAUNCHER" != "<none>" ]]; then
      VM_NAME="$LAUNCHER"
      log.info "Detected target launcher for VM: $VM_NAME"
      break
    fi
    log.verbose "Waiting for VMIM or target launcher..."
    sleep "$POLL"
  done
  step.end "PASS"
fi

log.info "Tracking VM: $VM_NAME"

step.begin "[2/3] RESOLVE TARGET NODE"
log.info "Waiting for target virt-launcher to get a node..."
LAST_PHASE=""
while true; do
  VMIM_PHASE=$(oc --kubeconfig "$SKC" get vmim -n default --no-headers \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' 2>/dev/null \
    | grep -i "forklift\|$VM_NAME" | head -1 || echo "-- no vmim yet")

  GREEN_NODE=$(oc --kubeconfig "$TKC" get pods -n default \
    -l "kubevirt.io/vm=$VM_NAME" \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)

  CURRENT_PHASE=$(echo "$VMIM_PHASE" | awk '{print $NF}')
  if [[ "$CURRENT_PHASE" != "$LAST_PHASE" ]]; then
    log.info "VMIM: $VMIM_PHASE | Green node: ${GREEN_NODE:-pending}"
    LAST_PHASE="$CURRENT_PHASE"
  else
    log.verbose "VMIM: $VMIM_PHASE | Green node: ${GREEN_NODE:-pending}"
  fi

  if [[ -n "$GREEN_NODE" ]]; then
    log.info "Target node resolved: $GREEN_NODE"
    step.end "PASS"
    break
  fi

  VMIM_STATUS=$(echo "$VMIM_PHASE" | awk '{print $NF}')
  if [[ "$VMIM_STATUS" == "Succeeded" ]]; then
    log.error "VMIM already Succeeded — too late for chaos injection."
    step.end "FAIL"
    exit 1
  fi

  sleep "$POLL"
done

step.begin "[3/3] FIRE CHAOS"
log.info "Target: virt-handler on $GREEN_NODE  VM: $VM_NAME"

krknctl run pod-scenarios \
  --kubeconfig "$TKC" \
  --namespace openshift-cnv \
  --pod-label 'kubevirt.io=virt-handler' \
  --node-label-selector "kubernetes.io/hostname=$GREEN_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 240

step.end "PASS"
log.success "Chaos injection complete."
