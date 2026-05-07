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

# ── Shared libraries ──────────────────────────────────────────
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

WORKLOAD_DIR="${TEMPLATE_DIR}/vm-workloads"
[[ -d "$WORKLOAD_DIR" ]] || { log.error "Workload templates not found: ${WORKLOAD_DIR}"; exit 1; }
[[ -f "$WORKLOAD_DIR/setup.sh" ]] || { log.error "Guest setup script not found: ${WORKLOAD_DIR}/setup.sh"; exit 1; }

export KUBECONFIG="$KUBECONFIG_PATH"

log.verbose "VM Workload Setup: ${VM_NAME}"

# ── Wait for SSH ──────────────────────────────────────────────
wait_for_guest_ssh

# ── Transfer workload bundle ──────────────────────────────────
task.begin "Transferring bundle"
log.debug "tar -czf - -C '${TEMPLATE_DIR}' vm-workloads | base64"
BUNDLE=$(tar -czf - -C "${TEMPLATE_DIR}" vm-workloads | base64)
run_on_vm "echo '${BUNDLE}' | base64 -d | sudo tar -xzf - -C /tmp/ && echo 'Bundle extracted to /tmp/vm-workloads/'" >/dev/null 2>&1
task.pass "Bundle transferred"

# ── Run guest-side setup ──────────────────────────────────────
task.begin "Running guest setup"
GUEST_EXIT=0
GUEST_OUTPUT=$(run_on_vm "sudo bash /tmp/vm-workloads/setup.sh ${LARGE_DATA_SIZE_MB} ${LARGE_DATA_SIZE_MB_EPHEMERAL}" 2>&1) || GUEST_EXIT=$?

if [[ "$GUEST_EXIT" -ne 0 ]]; then
  task.fail "Guest setup" "exit code ${GUEST_EXIT}"
  log.info ""
  log.info "$GUEST_OUTPUT"
  exit 1
fi

task.pass "Guest setup (6 workloads)"
log.verbose "$GUEST_OUTPUT"
