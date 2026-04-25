#!/usr/bin/env bash
set -euo pipefail

#
# Host-side orchestrator: copies workload templates to the VM and runs
# the guest-side setup script.
#
# The actual setup logic (package install, service creation, data generation)
# lives in templates/vm-workloads/setup.sh and runs INSIDE the VM.
# Service files live as standalone .service files in templates/vm-workloads/services/.
#
# This script handles:
#   1. Waiting for guest SSH to become reachable
#   2. Transferring the workload bundle to the VM (base64-encoded tar)
#   3. Invoking the guest-side setup.sh via sudo
#
# Usage:
#   ./setup-vm-workloads.sh --kubeconfig <path> --vm <name> [OPTIONS]
#
# Example:
#   ./setup-vm-workloads.sh \
#     --kubeconfig /path/to/kubeconfig \
#     --vm mercury-vm \
#     --namespace default \
#     --ssh-key ~/.ssh/id_rsa \
#     --template-dir /path/to/templates
#

NAMESPACE="default"
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="centos"
VM_NAME=""
KUBECONFIG_PATH=""
LOCAL_SSH_OPTS=""
SSH_READY_TIMEOUT=600
SSH_READY_INTERVAL=15
LARGE_DATA_SIZE_MB=500
LARGE_DATA_SIZE_MB_EPHEMERAL=100
TEMPLATE_DIR=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Setup VM workloads by copying templates and running the guest-side setup script.

Required:
  --kubeconfig PATH                  Path to cluster kubeconfig
  --vm NAME                          VM name

Optional:
  --namespace NS                     Namespace (default: default)
  --ssh-key PATH                     Private SSH key (default: ~/.ssh/id_rsa)
  --ssh-user USER                    SSH user inside VM (default: centos)
  --template-dir DIR                 Templates directory (auto-detected if not set)
  --local-ssh-opts OPTS              Extra options for virtctl ssh
  --ssh-ready-timeout SEC            Max seconds to wait for guest SSH (default: 600)
  --large-data-size-mb MB            Size of persistent test data in MB (default: 500)
  --large-data-size-mb-ephemeral MB  Size of ephemeral test data in MB (default: 100)

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)                  KUBECONFIG_PATH="$2"; shift 2 ;;
    --vm)                          VM_NAME="$2"; shift 2 ;;
    --namespace)                   NAMESPACE="$2"; shift 2 ;;
    --ssh-key)                     SSH_KEY="$2"; shift 2 ;;
    --ssh-user)                    SSH_USER="$2"; shift 2 ;;
    --template-dir)                TEMPLATE_DIR="$2"; shift 2 ;;
    --local-ssh-opts)              LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout)           SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --large-data-size-mb)          LARGE_DATA_SIZE_MB="$2"; shift 2 ;;
    --large-data-size-mb-ephemeral) LARGE_DATA_SIZE_MB_EPHEMERAL="$2"; shift 2 ;;
    -h|--help)                     usage ;;
    *)                             echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]]         && { echo "ERROR: --vm is required"; usage; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-${SCRIPT_DIR}/../../templates}"

WORKLOAD_DIR="${TEMPLATE_DIR}/vm-workloads"
[[ -d "$WORKLOAD_DIR" ]] || { echo "ERROR: Workload templates not found: ${WORKLOAD_DIR}"; exit 1; }
[[ -f "$WORKLOAD_DIR/setup.sh" ]] || { echo "ERROR: Guest setup script not found: ${WORKLOAD_DIR}/setup.sh"; exit 1; }

if [[ -z "${SSH_READY_TIMEOUT:-}" ]] || ! [[ "${SSH_READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  SSH_READY_TIMEOUT=600
fi
if [[ -z "${SSH_READY_INTERVAL:-}" ]] || ! [[ "${SSH_READY_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${SSH_READY_INTERVAL}" -eq 0 ]]; then
  SSH_READY_INTERVAL=15
fi

export KUBECONFIG="$KUBECONFIG_PATH"

run_on_vm() {
  virtctl ssh "${SSH_USER}@vm/${VM_NAME}" \
    --namespace "$NAMESPACE" \
    --identity-file="$SSH_KEY" \
    --local-ssh-opts="-o StrictHostKeyChecking=no" \
    --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
    --command "$1"
}

wait_for_guest_ssh() {
  if [[ "${SSH_READY_TIMEOUT}" -eq 0 ]]; then
    return 0
  fi
  local max_attempts=$(( SSH_READY_TIMEOUT / SSH_READY_INTERVAL ))
  if [[ "${max_attempts}" -lt 1 ]]; then
    max_attempts=1
  fi
  local attempt=1
  echo "Waiting for guest SSH (virtctl) — up to ${SSH_READY_TIMEOUT}s, every ${SSH_READY_INTERVAL}s..."
  while [[ "${attempt}" -le "${max_attempts}" ]]; do
    if run_on_vm "true" >/dev/null 2>&1; then
      echo "Guest SSH is reachable (attempt ${attempt}/${max_attempts})."
      echo ""
      return 0
    fi
    echo "  SSH not ready yet (attempt ${attempt}/${max_attempts}), retrying in ${SSH_READY_INTERVAL}s..."
    sleep "${SSH_READY_INTERVAL}"
    attempt=$(( attempt + 1 ))
  done
  echo "ERROR: Guest SSH did not become reachable within ${SSH_READY_TIMEOUT}s."
  exit 1
}

echo "============================================"
echo "  VM Workload Setup: ${VM_NAME}"
echo "============================================"
echo ""

wait_for_guest_ssh

# ── Transfer workload bundle to VM ────────────────────────
#
# Pack the vm-workloads directory into a base64-encoded tarball and
# unpack it on the VM in a single SSH call. This avoids depending on
# virtctl scp (which may not work through all tunnel setups) and
# reduces the transfer to one SSH session.

echo "Transferring workload bundle to VM..."
BUNDLE=$(tar -czf - -C "${TEMPLATE_DIR}" vm-workloads | base64)

run_on_vm "echo '${BUNDLE}' | base64 -d | sudo tar -xzf - -C /tmp/ && echo 'Bundle extracted to /tmp/vm-workloads/'"

# ── Run guest-side setup ──────────────────────────────────

echo "Running setup on VM..."
echo ""
run_on_vm "sudo bash /tmp/vm-workloads/setup.sh ${LARGE_DATA_SIZE_MB} ${LARGE_DATA_SIZE_MB_EPHEMERAL}"
