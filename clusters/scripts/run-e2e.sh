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
  --ssh-ready-timeout SEC    Max seconds to wait for guest SSH before setup (default: 600)

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
    --local-ssh-opts)       LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout)    SSH_READY_TIMEOUT="$2"; shift 2 ;;
    -h|--help)              usage ;;
    *)                   echo "Unknown option: $1"; usage ;;
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

echo ">>> [1/6] create-vm"
"${SCRIPT_DIR}/create-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "${SSH_KEY}.pub" \
  --template "${TEMPLATE_DIR}/vm.yaml.template" \
  --output-dir "$GENERATED_DIR"

echo ""
echo ">>> [2/6] setup workloads (SSH)"
"${SCRIPT_DIR}/setup-vm-workloads.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --ssh-ready-timeout "$SSH_READY_TIMEOUT" \
  --local-ssh-opts "$LOCAL_SSH_OPTS"

echo ""
echo ">>> [3/6] pre-migration check"
"${SCRIPT_DIR}/pre-migration-check.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$REPORT_DIR" \
  --local-ssh-opts "$LOCAL_SSH_OPTS"

PRE_FILE="$(ls -t "${REPORT_DIR}/pre-migration-${VM_NAME}-"*.json 2>/dev/null | head -1 || true)"
[[ -n "$PRE_FILE" ]] || { echo "ERROR: Could not find pre-migration JSON for ${VM_NAME}"; exit 1; }
echo "Using pre-migration baseline: ${PRE_FILE}"

echo ""
echo ">>> [4/6] migrate-vm (plan + trigger)"
"${SCRIPT_DIR}/migrate-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --template-dir "$TEMPLATE_DIR" \
  --output-dir "$GENERATED_DIR"

echo ""
echo ">>> [5/6] wait for migration completion (up to 10 checks, 60s apart)"
MAX_ATTEMPTS=10
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
    echo "ERROR: Migration did not complete after ${MAX_ATTEMPTS} checks (~$((MAX_ATTEMPTS * 60))s max wait between first and last check)."
    KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" -n openshift-mtv -o yaml || true
    exit 1
  fi
  echo "  Check ${i}/${MAX_ATTEMPTS}: phase=${phase:-pending} Succeeded=${succ:-n/a} — sleeping 60s..."
  sleep 60
done

echo ""
echo ">>> [6/6] post-migration check (target cluster)"
"${SCRIPT_DIR}/post-migration-check.sh" \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$REPORT_DIR" \
  --pre-migration-file "$PRE_FILE" \
  --local-ssh-opts "$LOCAL_SSH_OPTS"

echo ""
echo "================================================================"
echo "  E2E completed for VM: ${VM_NAME}"
echo "================================================================"
echo ""
