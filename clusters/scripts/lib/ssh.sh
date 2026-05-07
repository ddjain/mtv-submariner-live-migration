#!/usr/bin/env bash
# clusters/scripts/lib/ssh.sh — Shared SSH helpers for virtctl-based VM access.
#
# Provides run_on_vm() and wait_for_guest_ssh().
# Requires lib/log.sh to be sourced first.
#
# Callers MUST set these variables before sourcing:
#   SSH_USER       — SSH user inside VM (e.g. "centos")
#   VM_NAME        — VM name
#   NAMESPACE      — Kubernetes namespace
#   SSH_KEY        — Path to private SSH key
#
# Optional (have defaults):
#   SSH_READY_TIMEOUT   — Max seconds to wait for SSH (default: 600)
#   SSH_READY_INTERVAL  — Seconds between retries (default: 15)

[[ -n "${_SSH_SH_LOADED:-}" ]] && return 0
_SSH_SH_LOADED=1

SSH_READY_TIMEOUT="${SSH_READY_TIMEOUT:-600}"
SSH_READY_INTERVAL="${SSH_READY_INTERVAL:-5}"

# Validate timeout parameters
if ! [[ "${SSH_READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  SSH_READY_TIMEOUT=600
fi
if ! [[ "${SSH_READY_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${SSH_READY_INTERVAL}" -eq 0 ]]; then
  SSH_READY_INTERVAL=5
fi

# ── run_on_vm ─────────────────────────────────────────────────
# Execute a command inside the VM via virtctl ssh.
#
# CRITICAL: This function's stdout is frequently captured into
# variables (VM_DATA, SQLITE_GAP_DATA, etc.) for JSON/key=value
# parsing. It must NEVER emit any logging or ANSI to stdout.
# All diagnostics go to log.debug_err (stderr).
run_on_vm() {
  log.debug_err "run_on_vm: virtctl ssh ${SSH_USER}@vm/${VM_NAME} --command '${1:0:80}...'"
  virtctl ssh "${SSH_USER}@vm/${VM_NAME}" \
    --namespace "$NAMESPACE" \
    --identity-file="$SSH_KEY" \
    --local-ssh-opts="-o StrictHostKeyChecking=no" \
    --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
    --command "$1"
}

# ── wait_for_guest_ssh ────────────────────────────────────────
# Poll until SSH is reachable via virtctl, with structured
# logging integration. Shows retries at verbose level, and a
# compact same-line progress at normal level (TTY only).
wait_for_guest_ssh() {
  if [[ "${SSH_READY_TIMEOUT}" -eq 0 ]]; then
    return 0
  fi

  local max_attempts=$(( SSH_READY_TIMEOUT / SSH_READY_INTERVAL ))
  [[ "$max_attempts" -lt 1 ]] && max_attempts=1

  local attempt=1
  task.begin "Waiting for SSH"
  log.verbose "Timeout: ${SSH_READY_TIMEOUT}s, interval: ${SSH_READY_INTERVAL}s, max attempts: ${max_attempts}"

  while [[ "$attempt" -le "$max_attempts" ]]; do
    if run_on_vm "true" >/dev/null 2>&1; then
      task.pass "SSH Ready" "(attempt ${attempt}/${max_attempts})"
      return 0
    fi
    log.verbose "SSH not ready (attempt ${attempt}/${max_attempts}), retrying in ${SSH_READY_INTERVAL}s..."
    progress.update "Waiting for SSH" "attempt ${attempt}/${max_attempts}"
    sleep "${SSH_READY_INTERVAL}"
    attempt=$(( attempt + 1 ))
  done

  task.fail "SSH Timeout" "not reachable after ${SSH_READY_TIMEOUT}s"
  return 1
}
