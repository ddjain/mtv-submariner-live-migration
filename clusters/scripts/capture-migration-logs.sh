#!/usr/bin/env bash
#
# capture-migration-logs.sh
#
# Captures pod logs, resource watches, and events from both blue (source)
# and green (destination) clusters during a CCLM live migration.
#
# All collectors run in the background. Run this BEFORE starting the migration,
# then press Ctrl-C (or run `kill -- -$$`) to stop collection after migration ends.
#
# Usage:
#   ./capture-migration-logs.sh [--vm <vm-name>] [--namespace <ns>] [--duration <seconds>]
#
# Outputs are saved to: clusters-v2/cclm-migration-logs/<timestamp>/

set -euo pipefail

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCLM_ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BLUE_KUBECONFIG="${BLUE_KUBECONFIG:-${CCLM_ENV_DIR}/blue-cluster/auth/kubeconfig}"
GREEN_KUBECONFIG="${GREEN_KUBECONFIG:-${CCLM_ENV_DIR}/green-cluster/auth/kubeconfig}"

VM_NAME="${VM_NAME:-venus-vm}"
VM_NAMESPACE="${VM_NAMESPACE:-default}"
DURATION=""

LOG_BASE_DIR="${CCLM_ENV_DIR}/../cclm-migration-logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${LOG_BASE_DIR}/${TIMESTAMP}"

PIDS=()

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)        VM_NAME="$2"; shift 2 ;;
        --namespace) VM_NAMESPACE="$2"; shift 2 ;;
        --duration)  DURATION="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--vm <name>] [--namespace <ns>] [--duration <seconds>]"
            echo ""
            echo "Options:"
            echo "  --vm         VM name to track (default: venus-vm)"
            echo "  --namespace  Namespace of the VM (default: default)"
            echo "  --duration   Auto-stop after N seconds (default: run until Ctrl-C)"
            echo ""
            echo "Environment variables:"
            echo "  BLUE_KUBECONFIG   Path to blue cluster kubeconfig"
            echo "  GREEN_KUBECONFIG  Path to green cluster kubeconfig"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

cleanup() {
    echo ""
    echo ">>> Stopping all log collectors..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    echo ">>> Logs saved to: ${LOG_DIR}"
    echo ">>> Files collected:"
    ls -1 "${LOG_DIR}"
}

trap cleanup EXIT INT TERM

bg_log() {
    local label="$1"; shift
    ( "$@" || true ) >> "${LOG_DIR}/${label}" 2>&1 &
    PIDS+=($!)
    echo "  [PID $!] ${label}"
}

find_pod() {
    local kubeconfig="$1" namespace="$2" selector="$3"
    KUBECONFIG="$kubeconfig" kubectl get pods -n "$namespace" \
        -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

find_pods() {
    local kubeconfig="$1" namespace="$2" selector="$3"
    KUBECONFIG="$kubeconfig" kubectl get pods -n "$namespace" \
        -l "$selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
}

# ──────────────────────────────────────────────
# Preflight checks
# ──────────────────────────────────────────────

echo "============================================="
echo " CCLM Migration Log Capture"
echo "============================================="
echo "  VM:           ${VM_NAME}"
echo "  Namespace:    ${VM_NAMESPACE}"
echo "  Blue config:  ${BLUE_KUBECONFIG}"
echo "  Green config: ${GREEN_KUBECONFIG}"
echo "  Output dir:   ${LOG_DIR}"
echo "  Duration:     ${DURATION:-until Ctrl-C}"
echo "============================================="
echo ""

for kc in "$BLUE_KUBECONFIG" "$GREEN_KUBECONFIG"; do
    if [[ ! -f "$kc" ]]; then
        echo "ERROR: kubeconfig not found: $kc"
        exit 1
    fi
done

mkdir -p "${LOG_DIR}"

# ──────────────────────────────────────────────
# Snapshot: capture current pod state
# ──────────────────────────────────────────────

echo ">>> Capturing initial cluster state..."

{
    echo "=== Blue: openshift-cnv pods ==="
    KUBECONFIG="$BLUE_KUBECONFIG" kubectl get pods -n openshift-cnv -o wide 2>&1
    echo ""
    echo "=== Blue: openshift-mtv pods ==="
    KUBECONFIG="$BLUE_KUBECONFIG" kubectl get pods -n openshift-mtv -o wide 2>&1
    echo ""
    echo "=== Blue: submariner-operator pods ==="
    KUBECONFIG="$BLUE_KUBECONFIG" kubectl get pods -n submariner-operator -o wide 2>&1
    echo ""
    echo "=== Blue: VMs and VMIs (${VM_NAMESPACE}) ==="
    KUBECONFIG="$BLUE_KUBECONFIG" kubectl get vm,vmi -n "$VM_NAMESPACE" -o wide 2>&1
} > "${LOG_DIR}/blue-initial-state.log"

{
    echo "=== Green: openshift-cnv pods ==="
    KUBECONFIG="$GREEN_KUBECONFIG" kubectl get pods -n openshift-cnv -o wide 2>&1
    echo ""
    echo "=== Green: openshift-mtv pods ==="
    KUBECONFIG="$GREEN_KUBECONFIG" kubectl get pods -n openshift-mtv -o wide 2>&1
    echo ""
    echo "=== Green: submariner-operator pods ==="
    KUBECONFIG="$GREEN_KUBECONFIG" kubectl get pods -n submariner-operator -o wide 2>&1
    echo ""
    echo "=== Green: VMs and VMIs (${VM_NAMESPACE}) ==="
    KUBECONFIG="$GREEN_KUBECONFIG" kubectl get vm,vmi -n "$VM_NAMESPACE" -o wide 2>&1
} > "${LOG_DIR}/green-initial-state.log"

echo ">>> Initial state captured."
echo ""

# ══════════════════════════════════════════════
#  BLUE CLUSTER (Source) Log Collectors
# ══════════════════════════════════════════════

echo ">>> Starting BLUE (source) cluster collectors..."

# --- Pod logs ---

bg_log "blue-forklift-controller.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl logs -f deployment/forklift-controller -n openshift-mtv --all-containers --since=5m

bg_log "blue-virt-controller.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl logs -f deployment/virt-controller -n openshift-cnv --all-containers --since=5m

bg_log "blue-virt-handler.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl logs -f -n openshift-cnv -l kubevirt.io=virt-handler --all-containers --since=5m --max-log-requests=20

bg_log "blue-virt-launcher-${VM_NAME}.log" \
    bash -c "
        export KUBECONFIG='${BLUE_KUBECONFIG}'
        while true; do
            POD=\$(kubectl get pods -n '${VM_NAMESPACE}' \
                -l kubevirt.io/domain='${VM_NAME}' \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -n \"\$POD\" ]]; then
                echo \"Found launcher pod: \$POD\"
                kubectl logs -f -n '${VM_NAMESPACE}' \"\$POD\" --all-containers 2>&1
                break
            fi
            sleep 2
        done
    "

bg_log "blue-virt-sync.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl logs -f deployment/virt-synchronization-controller -n openshift-cnv --all-containers --since=5m

bg_log "blue-submariner-gw.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl logs -f daemonset/submariner-gateway -n submariner-operator --all-containers --since=5m

# --- Resource watches ---

bg_log "blue-vm-watch.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get vm -n "$VM_NAMESPACE" -w

bg_log "blue-vmi-watch.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get vmi -n "$VM_NAMESPACE" -w

bg_log "blue-vmim-watch.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get vmim -A -w

bg_log "blue-migration-watch.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get migration -n openshift-mtv -w

bg_log "blue-plan-watch.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get plan -n openshift-mtv -w

# --- Events ---

bg_log "blue-mtv-events.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get events -n openshift-mtv -w

bg_log "blue-cnv-events.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get events -n openshift-cnv -w

bg_log "blue-default-events.log" \
    env KUBECONFIG="$BLUE_KUBECONFIG" \
    kubectl get events -n "$VM_NAMESPACE" -w

echo ""

# ══════════════════════════════════════════════
#  GREEN CLUSTER (Destination) Log Collectors
# ══════════════════════════════════════════════

echo ">>> Starting GREEN (destination) cluster collectors..."

# --- Pod logs ---

bg_log "green-forklift-controller.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl logs -f deployment/forklift-controller -n openshift-mtv --all-containers --since=5m

bg_log "green-virt-controller.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl logs -f deployment/virt-controller -n openshift-cnv --all-containers --since=5m

bg_log "green-virt-handler.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl logs -f -n openshift-cnv -l kubevirt.io=virt-handler --all-containers --since=5m --max-log-requests=20

# Green virt-launcher — poll until the pod appears (created mid-migration)
bg_log "green-virt-launcher-${VM_NAME}.log" \
    bash -c "
        export KUBECONFIG='${GREEN_KUBECONFIG}'
        echo 'Waiting for virt-launcher pod on green...'
        while true; do
            POD=\$(kubectl get pods -n '${VM_NAMESPACE}' \
                -l kubevirt.io/domain='${VM_NAME}' \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -n \"\$POD\" ]]; then
                echo \"Found launcher pod: \$POD\"
                kubectl logs -f -n '${VM_NAMESPACE}' \"\$POD\" --all-containers 2>&1
                break
            fi
            sleep 2
        done
    "

bg_log "green-virt-sync.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl logs -f deployment/virt-synchronization-controller -n openshift-cnv --all-containers --since=5m

bg_log "green-submariner-gw.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl logs -f daemonset/submariner-gateway -n submariner-operator --all-containers --since=5m

# CDI importer pods (disk import on destination — poll since they appear dynamically)
bg_log "green-cdi-importer.log" \
    bash -c "
        export KUBECONFIG='${GREEN_KUBECONFIG}'
        echo 'Watching for CDI importer pods...'
        SEEN=''
        while true; do
            PODS=\$(kubectl get pods -n '${VM_NAMESPACE}' \
                -l cdi.kubevirt.io=importer \
                -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
            if [[ -n \"\$PODS\" ]]; then
                for p in \$PODS; do
                    if [[ ! \"\$SEEN\" =~ \"\$p\" ]]; then
                        echo \"=== Importer pod: \$p ===\"
                        kubectl logs -n '${VM_NAMESPACE}' \"\$p\" --all-containers 2>&1
                        SEEN=\"\$SEEN \$p\"
                    fi
                done
            fi
            sleep 5
        done
    "

# --- Resource watches ---

bg_log "green-vm-watch.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl get vm -n "$VM_NAMESPACE" -w

bg_log "green-vmi-watch.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl get vmi -n "$VM_NAMESPACE" -w

bg_log "green-vmim-watch.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl get vmim -A -w

bg_log "green-pvc-watch.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl get pvc -n "$VM_NAMESPACE" -w

# --- Events ---

bg_log "green-cnv-events.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl get events -n openshift-cnv -w

bg_log "green-default-events.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl get events -n "$VM_NAMESPACE" -w

bg_log "green-mtv-events.log" \
    env KUBECONFIG="$GREEN_KUBECONFIG" \
    kubectl get events -n openshift-mtv -w

echo ""
echo "============================================="
echo " All collectors running (${#PIDS[@]} processes)"
echo " Logs streaming to: ${LOG_DIR}"
echo " Press Ctrl-C to stop collection"
echo "============================================="
echo ""

# ──────────────────────────────────────────────
# Wait
# ──────────────────────────────────────────────

if [[ -n "$DURATION" ]]; then
    echo ">>> Auto-stopping in ${DURATION} seconds..."
    sleep "$DURATION"
else
    while true; do sleep 60; done
fi
