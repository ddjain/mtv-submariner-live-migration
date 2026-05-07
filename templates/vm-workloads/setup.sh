#!/bin/bash
#
# VM-side workload setup script.
# Runs INSIDE the guest VM after being copied via the host orchestrator.
#
# Usage (called by the host-side setup-vm-workloads.sh):
#   sudo bash /tmp/vm-workloads/setup.sh <large_data_mb> <large_data_ephemeral_mb>
#
set -euo pipefail

LARGE_DATA_SIZE_MB=${1:-100}
LARGE_DATA_SIZE_MB_EPHEMERAL=${2:-50}
WORKLOAD_DIR="/tmp/vm-workloads"

echo "============================================"
echo "  VM Workload Setup (guest-side)"
echo "  Persistent data:  ${LARGE_DATA_SIZE_MB}MB"
echo "  Ephemeral data:   ${LARGE_DATA_SIZE_MB_EPHEMERAL}MB"
echo "============================================"
echo ""

# ── [1/4] Packages & Directories ─────────────────────────

echo "[1/4] Installing packages and creating directories..."
mkdir -p /data/test /var/lib/test-ephemeral
dnf install -y sqlite cronie python3 2>&1 | tail -3
echo "      Done."
echo ""

# ── [2/4] Large Test Data (parallel, different disks) ────

echo "[2/4] Generating test data files in parallel..."

dd if=/dev/zero of=/data/large-file.bin \
  bs=1M count="${LARGE_DATA_SIZE_MB}" 2>/dev/null &
PID1=$!

dd if=/dev/zero of=/var/lib/test-ephemeral/large-file.bin \
  bs=1M count="${LARGE_DATA_SIZE_MB_EPHEMERAL}" 2>/dev/null &
PID2=$!

wait $PID1 $PID2
echo "      Persistent: $(stat -c%s /data/large-file.bin) bytes"
echo "      Ephemeral:  $(stat -c%s /var/lib/test-ephemeral/large-file.bin) bytes"
echo ""

# ── [3/4] Install Service Files & Crontab ────────────────

echo "[3/4] Installing systemd services and crontab..."
cp "${WORKLOAD_DIR}/services/"*.service /etc/systemd/system/
crontab "${WORKLOAD_DIR}/services/cron-job.crontab"

echo "      Installed:"
for f in "${WORKLOAD_DIR}/services/"*.service; do
  echo "        $(basename "$f")"
done
echo "        cron-job.crontab"
echo ""

# ── [4/4] Enable & Start Services ────────────────────────

echo "[4/4] Starting all services..."
systemctl daemon-reload
systemctl enable --now \
  file-writer \
  http-server \
  sqlite-writer \
  file-writer-ephemeral \
  sqlite-writer-ephemeral \
  crond

# Wait for first data to appear (up to 5s)
for _ in 1 2 3 4 5; do
  LINES=$(wc -l < /data/test/log.txt 2>/dev/null || echo 0)
  ROWS=$(sqlite3 /data/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)
  if [ "$LINES" -gt 0 ] && [ "$ROWS" -gt 0 ]; then break; fi
  sleep 1
done

echo ""
echo "============================================"
echo "  Verification"
echo "============================================"
echo ""
echo "  Service Status:"
echo "    Persistent (vdc /data/):"
printf "      %-30s %s\n" "file-writer"   "$(systemctl is-active file-writer)"
printf "      %-30s %s\n" "http-server"   "$(systemctl is-active http-server)"
printf "      %-30s %s\n" "sqlite-writer" "$(systemctl is-active sqlite-writer)"
printf "      %-30s %s\n" "crond"         "$(systemctl is-active crond)"
echo ""
echo "    Ephemeral (vda /var/lib/test-ephemeral/):"
printf "      %-30s %s\n" "file-writer-ephemeral"   "$(systemctl is-active file-writer-ephemeral)"
printf "      %-30s %s\n" "sqlite-writer-ephemeral" "$(systemctl is-active sqlite-writer-ephemeral)"
echo ""
echo "  Data Check:"
echo "    Persistent (vdc):"
echo "      log.txt lines:  $(wc -l < /data/test/log.txt 2>/dev/null || echo 0)"
echo "      SQLite rows:    $(sqlite3 /data/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)"
echo "      HTTP status:    $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)"
echo "    Ephemeral (vda):"
echo "      log.txt lines:  $(wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0)"
echo "      SQLite rows:    $(sqlite3 /var/lib/test-ephemeral/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)"
echo ""
echo "============================================"
echo "  Setup complete! 6 workloads running:"
echo "    - 4 persistent (vdc): file, http, sqlite, cron"
echo "    - 2 ephemeral (vda): file, sqlite"
echo "============================================"

rm -rf "${WORKLOAD_DIR}"

# Parseable summary line for host-side script to capture
SVC_COUNT=6
PERSISTENT_SVC="$(systemctl is-active file-writer 2>/dev/null || echo inactive),$(systemctl is-active sqlite-writer 2>/dev/null || echo inactive),$(systemctl is-active http-server 2>/dev/null || echo inactive),$(systemctl is-active crond 2>/dev/null || echo inactive)"
EPHEMERAL_SVC="$(systemctl is-active file-writer-ephemeral 2>/dev/null || echo inactive),$(systemctl is-active sqlite-writer-ephemeral 2>/dev/null || echo inactive)"
echo "SETUP_RESULT=OK services=${SVC_COUNT} persistent_mb=${LARGE_DATA_SIZE_MB} ephemeral_mb=${LARGE_DATA_SIZE_MB_EPHEMERAL} persistent_svc=${PERSISTENT_SVC} ephemeral_svc=${EPHEMERAL_SVC}"
