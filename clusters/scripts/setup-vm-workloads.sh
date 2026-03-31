#!/usr/bin/env bash
set -euo pipefail

#
# Setup script for VM workloads: file writer, HTTP server, cron job, SQLite writer.
# Installs required packages, creates systemd services so workloads survive reboots,
# and starts all services.
#
# Usage:
#   ./setup-vm-workloads.sh --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--local-ssh-opts <opts>] [--ssh-ready-timeout SEC]
#
# After the VM is Ready, the guest OS may still be booting / configuring network. This script waits for
# virtctl ssh to succeed before installing packages (default: up to 600s, check every 15s).
#
# Example:
#   ./setup-vm-workloads.sh \
#     --kubeconfig /path/to/kubeconfig \
#     --vm mercury-vm \
#     --namespace default \
#     --ssh-key ~/.ssh/id_rsa
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

usage() {
  echo "Usage: $0 --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--ssh-user <user>] [--local-ssh-opts <opts>] [--ssh-ready-timeout SEC] [--large-data-size-mb MB] [--large-data-size-mb-ephemeral MB]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)         KUBECONFIG_PATH="$2"; shift 2 ;;
    --vm)                 VM_NAME="$2"; shift 2 ;;
    --namespace)          NAMESPACE="$2"; shift 2 ;;
    --ssh-key)            SSH_KEY="$2"; shift 2 ;;
    --ssh-user)           SSH_USER="$2"; shift 2 ;;
    --local-ssh-opts)     LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout)  SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --large-data-size-mb) LARGE_DATA_SIZE_MB="$2"; shift 2 ;;
    --large-data-size-mb-ephemeral) LARGE_DATA_SIZE_MB_EPHEMERAL="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]] && { echo "ERROR: --vm is required"; usage; }

# Empty / non-numeric timeout breaks [[ -eq ]] and $(( )) under set -e (e.g. env SSH_READY_TIMEOUT= or a bad make argv).
if [[ -z "${SSH_READY_TIMEOUT:-}" ]] || ! [[ "${SSH_READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  SSH_READY_TIMEOUT=600
fi
if [[ -z "${SSH_READY_INTERVAL:-}" ]] || ! [[ "${SSH_READY_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${SSH_READY_INTERVAL}" -eq 0 ]]; then
  SSH_READY_INTERVAL=15
fi

# SSH options are now hardcoded in run_on_vm() function using two separate flags
# This ensures it works with both new and changed SSH host keys

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

# --- Step 1: Install packages ---
echo "[1/9] Installing required packages (sqlite, cronie, python3)..."
run_on_vm "sudo dnf install -y sqlite cronie python3 2>&1 | tail -3"
echo "      Done."
echo ""

# --- Step 2: Create persistent data directory on vdc ---
echo "[2/9] Creating /data/test directory on vdc (persistent)..."
run_on_vm "sudo mkdir -p /data/test && echo 'Directory created'"
echo ""

# --- Step 2b: Create ephemeral test directory on vda ---
echo "[2b/9] Creating /var/lib/test-ephemeral directory on vda (OS disk)..."
run_on_vm "sudo mkdir -p /var/lib/test-ephemeral && echo 'Directory created'"
echo ""

# --- Step 2.5: Generate large test data on vdc ---
echo "[2.5/9] Generating large test file on vdc (${LARGE_DATA_SIZE_MB}MB)..."
run_on_vm "sudo dd if=/dev/urandom of=/data/large-file.bin bs=1M count=${LARGE_DATA_SIZE_MB} status=progress 2>&1 | tail -1"
echo "      Done."
echo ""

# --- Step 2.7: Generate ephemeral large test data on vda ---
echo "[2.7/9] Generating ephemeral large test file on vda (${LARGE_DATA_SIZE_MB_EPHEMERAL}MB)..."
run_on_vm "sudo dd if=/dev/urandom of=/var/lib/test-ephemeral/large-file.bin bs=1M count=${LARGE_DATA_SIZE_MB_EPHEMERAL} status=progress 2>&1 | tail -1"
echo "      Done."
echo ""

# --- Step 3: Create systemd services ---
echo "[3/9] Creating systemd services..."

run_on_vm "sudo bash -c 'cat > /etc/systemd/system/file-writer.service << EOF
[Unit]
Description=Continuous File Writer
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c \"while true; do echo \\\"\\\$(date) - writing test data\\\" >> /data/test/log.txt; sleep 1; done\"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF'"
echo "      file-writer.service created"

run_on_vm "sudo bash -c 'cat > /etc/systemd/system/http-server.service << EOF
[Unit]
Description=Python HTTP Server on port 8080
After=network.target

[Service]
Type=simple
WorkingDirectory=/data
ExecStart=/usr/bin/python3 -m http.server 8080
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF'"
echo "      http-server.service created"

run_on_vm "sudo bash -c 'cat > /etc/systemd/system/sqlite-writer.service << EOF
[Unit]
Description=SQLite Database Writer
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c \"sqlite3 /data/test.db \\\"CREATE TABLE IF NOT EXISTS test (timestamp INTEGER);\\\"\"
ExecStart=/bin/bash -c \"while true; do echo \\\"INSERT INTO test VALUES (\\\$(date +%%s));\\\" | sqlite3 /data/test.db; sleep 2; done\"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF'"
echo "      sqlite-writer.service created"

# --- Ephemeral workloads on vda ---
run_on_vm "sudo bash -c 'cat > /etc/systemd/system/file-writer-ephemeral.service << EOF
[Unit]
Description=Ephemeral File Writer (vda)
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c \"while true; do echo \\\"\\\$(date) - ephemeral test data\\\" >> /var/lib/test-ephemeral/log.txt; sleep 1; done\"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF'"
echo "      file-writer-ephemeral.service created"

run_on_vm "sudo bash -c 'cat > /etc/systemd/system/sqlite-writer-ephemeral.service << EOF
[Unit]
Description=Ephemeral SQLite Writer (vda)
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c \"sqlite3 /var/lib/test-ephemeral/test.db \\\"CREATE TABLE IF NOT EXISTS test (timestamp INTEGER);\\\"\"
ExecStart=/bin/bash -c \"while true; do echo \\\"INSERT INTO test VALUES (\\\$(date +%%s));\\\" | sqlite3 /var/lib/test-ephemeral/test.db; sleep 2; done\"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF'"
echo "      sqlite-writer-ephemeral.service created"
echo ""

# --- Step 4: Setup cron job ---
echo "[4/9] Setting up cron job..."
run_on_vm "sudo bash -c 'echo \"* * * * * echo \\\"cron ran at \\\$(date)\\\" >> /data/test/cron.log\" | crontab -'"
echo "      Crontab entry installed"
echo ""

# --- Step 5: Enable and start all services ---
echo "[5/9] Enabling and starting all services..."
run_on_vm "sudo systemctl daemon-reload && \
  sudo systemctl enable --now file-writer.service && \
  sudo systemctl enable --now http-server.service && \
  sudo systemctl enable --now sqlite-writer.service && \
  sudo systemctl enable --now file-writer-ephemeral.service && \
  sudo systemctl enable --now sqlite-writer-ephemeral.service && \
  sudo systemctl enable --now crond"
echo "      All 6 services started"
echo ""

# --- Verify ---
echo "============================================"
echo "  Verification"
echo "============================================"
echo ""
run_on_vm "
echo 'Service Status:'
echo '  Persistent (vdc /data/):'
echo '    file-writer:   '  \$(systemctl is-active file-writer.service)
echo '    http-server:   '  \$(systemctl is-active http-server.service)
echo '    sqlite-writer: '  \$(systemctl is-active sqlite-writer.service)
echo '    crond:         '  \$(systemctl is-active crond)
echo ''
echo '  Ephemeral (vda /var/lib/test-ephemeral/):'
echo '    file-writer-ephemeral:   '  \$(systemctl is-active file-writer-ephemeral.service)
echo '    sqlite-writer-ephemeral: '  \$(systemctl is-active sqlite-writer-ephemeral.service)
echo ''
sleep 3
echo 'Quick data check:'
echo '  Persistent (vdc):'
echo '    log.txt lines:  ' \$(wc -l < /data/test/log.txt 2>/dev/null || echo 0)
echo '    SQLite rows:    ' \$(sudo sqlite3 /data/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)
echo '    HTTP status:    ' \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)
echo '  Ephemeral (vda):'
echo '    log.txt lines:  ' \$(wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0)
echo '    SQLite rows:    ' \$(sudo sqlite3 /var/lib/test-ephemeral/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)
"

echo ""
echo "============================================"
echo "  Setup complete! 6 workloads running:"
echo "    - 4 persistent (vdc): file, http, sqlite, cron"
echo "    - 2 ephemeral (vda): file, sqlite"
echo "============================================"
