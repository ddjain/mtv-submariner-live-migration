#!/usr/bin/env bash
#
# End-to-end: create VM -> setup workloads -> pre-check -> migrate -> wait for completion -> post-check
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_KUBECONFIG=""
TARGET_KUBECONFIG=""
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="centos"
NAMESPACE="default"
TEMPLATE_DIR=""
GENERATED_DIR=""
REPORT_DIR=""
VM_NAME=""
LOCAL_SSH_OPTS_DEFAULT="-o StrictHostKeyChecking=accept-new"
LOCAL_SSH_OPTS=""
SSH_READY_TIMEOUT=600
STABILIZE_WAIT=30
LARGE_DATA_SIZE_MB=500
LARGE_DATA_SIZE_MB_EPHEMERAL=100

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run the full migration pipeline with an optional random VM name.

Required:
  --source-kubeconfig PATH   Kubeconfig for source (blue) cluster
  --target-kubeconfig PATH   Kubeconfig for target (green) cluster

Optional:
  --vm NAME                  VM name (default: random prefix-base-vm)
  --namespace NS             Namespace (default: default)
  --ssh-key PATH             Private SSH key (default: ~/.ssh/id_rsa)
  --ssh-user USER            SSH user inside VM (default: centos)
  --template-dir DIR         Templates directory
  --output-dir DIR           Generated manifests dir (default: scripts/generated)
  --report-dir DIR           JSON reports dir (default: scripts/reports)
  --local-ssh-opts OPTS      Passed to virtctl ssh (default: -o StrictHostKeyChecking=accept-new)
  --ssh-ready-timeout SEC            Max seconds to wait for guest SSH before setup (default: 600)
  --stabilize-wait SEC               Seconds to wait after workload setup before pre-check (default: 30)
  --large-data-size-mb MB            Size of persistent test data file in MB (default: 500)
  --large-data-size-mb-ephemeral MB  Size of ephemeral test data file in MB (default: 100)

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-kubeconfig) SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --target-kubeconfig) TARGET_KUBECONFIG="$2"; shift 2 ;;
    --vm)                VM_NAME="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --ssh-key)           SSH_KEY="$2"; shift 2 ;;
    --ssh-user)          SSH_USER="$2"; shift 2 ;;
    --template-dir)      TEMPLATE_DIR="$2"; shift 2 ;;
    --output-dir)        GENERATED_DIR="$2"; shift 2 ;;
    --report-dir)        REPORT_DIR="$2"; shift 2 ;;
    --local-ssh-opts)                 LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout)              SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --stabilize-wait)                 STABILIZE_WAIT="$2"; shift 2 ;;
    --large-data-size-mb)             LARGE_DATA_SIZE_MB="$2"; shift 2 ;;
    --large-data-size-mb-ephemeral)   LARGE_DATA_SIZE_MB_EPHEMERAL="$2"; shift 2 ;;
    -h|--help)                        usage ;;
    *)                                echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SOURCE_KUBECONFIG" ]] && { echo "ERROR: --source-kubeconfig is required"; usage; }
[[ -z "$TARGET_KUBECONFIG" ]] && { echo "ERROR: --target-kubeconfig is required"; usage; }

TEMPLATE_DIR="${TEMPLATE_DIR:-${SCRIPT_DIR}/../../templates}"
GENERATED_DIR="${GENERATED_DIR:-${SCRIPT_DIR}/generated}"
REPORT_DIR="${REPORT_DIR:-${SCRIPT_DIR}/reports}"

if [[ -z "${LOCAL_SSH_OPTS}" ]]; then
  LOCAL_SSH_OPTS="$LOCAL_SSH_OPTS_DEFAULT"
fi

mkdir -p "$GENERATED_DIR" "$REPORT_DIR"

step_banner() {
  echo ""
  echo "================================================================"
  echo "  $1"
  echo "================================================================"
}

if [[ -z "$VM_NAME" ]]; then
  prefixes=(
    bright shadow silent rapid frozen burning gentle wild brave curious mighty swift
    ancient fancy glowing hidden icy lucky mystic noisy proud quick royal shiny
    stormy tiny vast wandering young zesty calm eager fierce jolly kind lively
    bold clever daring elegant fearless
  )
  names=(
    vm node engine core system cluster scout ranger pilot voyager tracker falcon tiger
    panther eagle wolf river forest storm breeze shadow flare ember spark pulse echo
    rift glitch fault breaker chaos atlas orion zephyr nova zenith
  )
  VM_NAME="${prefixes[$((RANDOM % ${#prefixes[@]}))]}-${names[$((RANDOM % ${#names[@]}))]}-vm"
fi

echo ""
echo "================================================================"
echo "  E2E Migration Pipeline"
echo "  VM_NAME:    ${VM_NAME}"
echo "  Namespace:  ${NAMESPACE}"
echo "================================================================"
echo ""

step_banner "[1/6] CREATE VM"
"${SCRIPT_DIR}/create-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "${SSH_KEY}.pub" \
  --template "${TEMPLATE_DIR}/vm.yaml.template" \
  --output-dir "$GENERATED_DIR"

echo ""
echo "  ---- VM Details (source cluster) ----"
echo "  Name:       ${VM_NAME}"
echo "  Namespace:  ${NAMESPACE}"
VM_NODE="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "n/a")"
VM_IP="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "n/a")"
VM_PHASE="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "n/a")"
VM_READY="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "n/a")"
echo "  Node:       ${VM_NODE}"
echo "  Pod IP:     ${VM_IP}"
echo "  VMI Phase:  ${VM_PHASE}"
echo "  VM Ready:   ${VM_READY}"
echo ""
echo "  # Copy-paste for krknctl / chaos (same variable names as your shell):"
echo "  export VM_NAME=\"${VM_NAME}\""
echo "  export KUBECONFIG_PATH=\"${SOURCE_KUBECONFIG}\""
echo "  export NAMESPACE=\"${NAMESPACE}\""
if [[ -n "${VM_NODE}" ]] && [[ "${VM_NODE}" != "n/a" ]]; then
  echo "  export NODE_LABEL_SELECTOR=\"kubernetes.io/hostname=${VM_NODE}\""
else
  echo "  export NODE_LABEL_SELECTOR=\"\"  # set node: kubectl get vmi ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.nodeName}'"
fi
echo "  --------------------------------------"

step_banner "[2/6] SETUP WORKLOADS"
"${SCRIPT_DIR}/setup-vm-workloads.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --ssh-ready-timeout "$SSH_READY_TIMEOUT" \
  --large-data-size-mb "$LARGE_DATA_SIZE_MB" \
  --large-data-size-mb-ephemeral "$LARGE_DATA_SIZE_MB_EPHEMERAL" \
  --local-ssh-opts "$LOCAL_SSH_OPTS"

echo ""
echo "  Waiting ${STABILIZE_WAIT}s for workloads to stabilize..."
sleep "${STABILIZE_WAIT}"

step_banner "[3/6] PRE-MIGRATION CHECK"
"${SCRIPT_DIR}/pre-migration-check.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$REPORT_DIR" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout 300

PRE_FILE="$(ls -t "${REPORT_DIR}/pre-migration-${VM_NAME}-"*.json 2>/dev/null | head -1 || true)"
[[ -n "$PRE_FILE" ]] || { echo "ERROR: Could not find pre-migration JSON for ${VM_NAME}"; exit 1; }
echo "Using pre-migration baseline: ${PRE_FILE}"

step_banner "[4/6] MIGRATE VM"
"${SCRIPT_DIR}/migrate-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --template-dir "$TEMPLATE_DIR" \
  --output-dir "$GENERATED_DIR"

step_banner "[5/6] WAIT FOR MIGRATION (up to 60 checks, 10s apart)"
MAX_ATTEMPTS=60
for i in $(seq 1 "$MAX_ATTEMPTS"); do
  phase="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" \
    -n openshift-mtv -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  succ="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" \
    -n openshift-mtv -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")"

  if [[ "$phase" == "Completed" ]] || [[ "$phase" == "Succeeded" ]] || [[ "$succ" == "True" ]]; then
    echo "Migration finished successfully (phase=${phase:-n/a}, Succeeded=${succ:-n/a})."
    break
  fi
  if [[ "$phase" == "Failed" ]]; then
    echo "ERROR: Migration phase is Failed."
    KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" -n openshift-mtv -o yaml || true
    exit 1
  fi
  if [[ "$i" -eq "$MAX_ATTEMPTS" ]]; then
    echo "ERROR: Migration did not complete after ${MAX_ATTEMPTS} checks (~$((MAX_ATTEMPTS * 10))s max wait)."
    KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" -n openshift-mtv -o yaml || true
    exit 1
  fi
  echo "  Check ${i}/${MAX_ATTEMPTS}: phase=${phase:-pending} Succeeded=${succ:-n/a} — sleeping 10s..."
  sleep 10
done

step_banner "[6/6] POST-MIGRATION CHECK (target cluster)"
"${SCRIPT_DIR}/post-migration-check.sh" \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$REPORT_DIR" \
  --pre-migration-file "$PRE_FILE" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout "$SSH_READY_TIMEOUT"

echo ""
echo "================================================================"
echo "  E2E completed for VM: ${VM_NAME}"
echo "================================================================"
echo ""
