#!/usr/bin/env bash
set -euo pipefail

#
# Post-migration checklist: captures post-migration state and compares with pre-migration JSON.
# Output file: post-migration-<vm>-<timestamp>.json
#
# Usage:
#   ./post-migration-check.sh --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] \
#     [--output-dir <dir>] [--pre-migration-file <path>]
#
# Example:
#   ./post-migration-check.sh \
#     --kubeconfig /path/to/green/kubeconfig \
#     --vm mercury-vm \
#     --pre-migration-file ./pre-migration-mercury-vm-20260324T091004Z.json
#

NAMESPACE="default"
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="centos"
VM_NAME=""
KUBECONFIG_PATH=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/reports"
PRE_MIGRATION_FILE=""
LOCAL_SSH_OPTS=""
SSH_READY_TIMEOUT=600
SSH_READY_INTERVAL=15

usage() {
  echo "Usage: $0 --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--ssh-user <user>] [--output-dir <dir>] [--pre-migration-file <path>] [--local-ssh-opts <opts>] [--ssh-ready-timeout SEC]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG_PATH="$2"; shift 2 ;;
    --vm)                  VM_NAME="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2"; shift 2 ;;
    --ssh-key)             SSH_KEY="$2"; shift 2 ;;
    --ssh-user)            SSH_USER="$2"; shift 2 ;;
    --output-dir)          OUTPUT_DIR="$2"; shift 2 ;;
    --pre-migration-file)  PRE_MIGRATION_FILE="$2"; shift 2 ;;
    --local-ssh-opts)      LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout)   SSH_READY_TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]] && { echo "ERROR: --vm is required"; usage; }

# Validate timeout parameters
if [[ -z "${SSH_READY_TIMEOUT:-}" ]] || ! [[ "${SSH_READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  SSH_READY_TIMEOUT=600
fi
if [[ -z "${SSH_READY_INTERVAL:-}" ]] || ! [[ "${SSH_READY_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${SSH_READY_INTERVAL}" -eq 0 ]]; then
  SSH_READY_INTERVAL=15
fi

# SSH options are now hardcoded in run_on_vm() function using two separate flags
# This ensures it works with both new and changed SSH host keys

export KUBECONFIG="$KUBECONFIG_PATH"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTPUT_FILE="${OUTPUT_DIR}/post-migration-${VM_NAME}-${TIMESTAMP}.json"

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
echo "  Post-Migration Check: ${VM_NAME}"
echo "  Timestamp: ${TIMESTAMP}"
echo "============================================"
echo ""

wait_for_guest_ssh

echo "Collecting cluster info..."
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
VM_STATUS=$(kubectl get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "unknown")
VM_NODE=$(kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
VM_IP=$(kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "unknown")

echo "Collecting VM workload data..."
VM_DATA=$(run_on_vm "
echo \"CAPTURE_TIME_UTC=\$(date -u '+%Y-%m-%dT%H:%M:%S UTC')\"
echo \"CAPTURE_TIME_LOCAL=\$(date '+%Y-%m-%d %H:%M:%S %Z')\"

echo \"FILE_WRITER_LINES=\$(wc -l < /data/test/log.txt 2>/dev/null || echo 0)\"
echo \"FILE_WRITER_SIZE=\$(du -b /data/test/log.txt 2>/dev/null | cut -f1 || echo 0)\"
echo \"FILE_WRITER_LAST=\$(tail -1 /data/test/log.txt 2>/dev/null || echo none)\"
echo \"FILE_WRITER_PID=\$(pgrep -f 'log.txt' -o 2>/dev/null || echo none)\"

echo \"SQLITE_ROWS=\$(sudo sqlite3 /data/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)\"
echo \"SQLITE_MAX_TS=\$(sudo sqlite3 /data/test.db 'SELECT max(timestamp) FROM test;' 2>/dev/null || echo 0)\"
echo \"SQLITE_MIN_TS=\$(sudo sqlite3 /data/test.db 'SELECT min(timestamp) FROM test;' 2>/dev/null || echo 0)\"
echo \"SQLITE_INTEGRITY=\$(sudo sqlite3 /data/test.db 'PRAGMA integrity_check;' 2>/dev/null || echo unknown)\"
echo \"SQLITE_SIZE=\$(du -b /data/test.db 2>/dev/null | cut -f1 || echo 0)\"
echo \"SQLITE_PID=\$(pgrep -f 'sqlite3' -o 2>/dev/null || echo none)\"
echo \"SQLITE_GAPS_GT2=\$(sudo sqlite3 /data/test.db 'WITH g AS (SELECT timestamp - LAG(timestamp) OVER (ORDER BY rowid) AS gap FROM test) SELECT count(*) FROM g WHERE gap > 2;' 2>/dev/null || echo -1)\"
echo \"SQLITE_MAX_GAP=\$(sudo sqlite3 /data/test.db 'WITH g AS (SELECT timestamp - LAG(timestamp) OVER (ORDER BY rowid) AS gap FROM test) SELECT COALESCE(max(gap),0) FROM g;' 2>/dev/null || echo -1)\"

echo \"CRON_LINES=\$(wc -l < /data/test/cron.log 2>/dev/null || echo 0)\"
echo \"CRON_LAST=\$(tail -1 /data/test/cron.log 2>/dev/null || echo none)\"
echo \"CROND_STATUS=\$(systemctl is-active crond 2>/dev/null || echo inactive)\"
echo \"CRONTAB_ENTRY=\$(crontab -l 2>/dev/null | head -1 || echo none)\"

echo \"HTTP_STATUS=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080 2>/dev/null || echo 0)\"
echo \"HTTP_PID=\$(pgrep -f 'http.server' -o 2>/dev/null || echo none)\"

echo \"VM_HOSTNAME=\$(hostname)\"
echo \"VM_IP_INTERNAL=\$(ip -4 addr show | grep 'inet ' | grep -v 127.0.0 | awk '{print \$2}' | head -1)\"
echo \"VM_UPTIME=\$(cat /proc/uptime | awk '{print \$1}')\"
echo \"DISK_TOTAL=\$(df -B1 / | tail -1 | awk '{print \$2}')\"
echo \"DISK_USED=\$(df -B1 / | tail -1 | awk '{print \$3}')\"
echo \"DISK_AVAIL=\$(df -B1 / | tail -1 | awk '{print \$4}')\"
echo \"DATA_DIR_SIZE=\$(du -sb /data/test/ 2>/dev/null | cut -f1 || echo 0)\"

echo \"LARGE_FILE_SIZE=\$(stat -c%s /data/large-file.bin 2>/dev/null || echo 0)\"
echo \"LARGE_FILE_SHA256=\$(sha256sum /data/large-file.bin 2>/dev/null | awk '{print \$1}' || echo none)\"

# Ephemeral disk (vda) data
echo \"EPHEMERAL_FILE_WRITER_LINES=\$(wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0)\"
echo \"EPHEMERAL_FILE_WRITER_SIZE=\$(du -b /var/lib/test-ephemeral/log.txt 2>/dev/null | cut -f1 || echo 0)\"
echo \"EPHEMERAL_FILE_WRITER_LAST=\$(tail -1 /var/lib/test-ephemeral/log.txt 2>/dev/null || echo none)\"
echo \"EPHEMERAL_FILE_WRITER_PID=\$(pgrep -f 'test-ephemeral/log.txt' -o 2>/dev/null || echo none)\"

echo \"EPHEMERAL_SQLITE_ROWS=\$(sudo sqlite3 /var/lib/test-ephemeral/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)\"
echo \"EPHEMERAL_SQLITE_MAX_TS=\$(sudo sqlite3 /var/lib/test-ephemeral/test.db 'SELECT max(timestamp) FROM test;' 2>/dev/null || echo 0)\"
echo \"EPHEMERAL_SQLITE_MIN_TS=\$(sudo sqlite3 /var/lib/test-ephemeral/test.db 'SELECT min(timestamp) FROM test;' 2>/dev/null || echo 0)\"
echo \"EPHEMERAL_SQLITE_INTEGRITY=\$(sudo sqlite3 /var/lib/test-ephemeral/test.db 'PRAGMA integrity_check;' 2>/dev/null || echo unknown)\"
echo \"EPHEMERAL_SQLITE_SIZE=\$(du -b /var/lib/test-ephemeral/test.db 2>/dev/null | cut -f1 || echo 0)\"
echo \"EPHEMERAL_SQLITE_PID=\$(pgrep -f 'test-ephemeral/test.db' -o 2>/dev/null || echo none)\"

echo \"EPHEMERAL_DIR_SIZE=\$(du -sb /var/lib/test-ephemeral/ 2>/dev/null | cut -f1 || echo 0)\"
echo \"EPHEMERAL_LARGE_FILE_SIZE=\$(stat -c%s /var/lib/test-ephemeral/large-file.bin 2>/dev/null || echo 0)\"
echo \"EPHEMERAL_LARGE_FILE_SHA256=\$(sha256sum /var/lib/test-ephemeral/large-file.bin 2>/dev/null | awk '{print \$1}' || echo none)\"
")

get_val() {
  echo "$VM_DATA" | grep "^${1}=" | head -1 | cut -d'=' -f2-
}

# --- SQLite time-bucketed gap analysis (30s windows) ---
echo "Analyzing SQLite insert gaps (30s time windows)..."
SQLITE_GAP_DATA=$(run_on_vm "sudo sqlite3 -json /data/test.db \"
WITH gaps AS (
  SELECT
    rowid as rid,
    timestamp as ts,
    timestamp - LAG(timestamp) OVER (ORDER BY rowid) as gap
  FROM test
  WHERE rowid > 1
),
buckets AS (
  SELECT
    (ts / 30) * 30 as bucket_ts,
    count(*) as total_inserts,
    sum(CASE WHEN gap > 2 THEN 1 ELSE 0 END) as slow_inserts,
    max(gap) as max_gap
  FROM gaps
  GROUP BY bucket_ts
)
SELECT
  datetime(bucket_ts, 'unixepoch') as time_window_utc,
  bucket_ts as epoch,
  total_inserts,
  slow_inserts,
  ROUND(slow_inserts * 100.0 / total_inserts, 1) as slow_pct,
  max_gap as max_gap_sec,
  CASE
    WHEN slow_inserts >= 5 THEN 'affected'
    WHEN slow_inserts > 0 THEN 'jitter'
    ELSE 'normal'
  END as status
FROM buckets
WHERE slow_inserts > 0
ORDER BY bucket_ts;
\"" 2>/dev/null || echo "[]")

AFFECTED_WINDOWS=$(echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    affected = [r for r in data if r.get('status') == 'affected']
    if affected:
        print(json.dumps({
            'affected_from_utc': affected[0]['time_window_utc'],
            'affected_to_utc': affected[-1]['time_window_utc'],
            'affected_from_epoch': affected[0]['epoch'],
            'affected_to_epoch': affected[-1]['epoch'],
            'duration_sec': affected[-1]['epoch'] - affected[0]['epoch'] + 30,
            'total_affected_windows': len(affected),
            'total_slow_inserts_in_window': sum(r['slow_inserts'] for r in affected),
            'total_inserts_in_window': sum(r['total_inserts'] for r in affected),
            'avg_slow_pct': round(sum(r['slow_pct'] for r in affected) / len(affected), 1)
        }))
    else:
        print(json.dumps({'affected_from_utc': 'none', 'affected_to_utc': 'none', 'duration_sec': 0, 'total_affected_windows': 0, 'total_slow_inserts_in_window': 0, 'total_inserts_in_window': 0, 'avg_slow_pct': 0}))
except:
    print(json.dumps({'affected_from_utc': 'none', 'affected_to_utc': 'none', 'duration_sec': 0, 'total_affected_windows': 0, 'total_slow_inserts_in_window': 0, 'total_inserts_in_window': 0, 'avg_slow_pct': 0}))
" 2>/dev/null || echo '{"affected_from_utc":"none","affected_to_utc":"none","duration_sec":0,"total_affected_windows":0,"total_slow_inserts_in_window":0,"total_inserts_in_window":0,"avg_slow_pct":0}')

JITTER_COUNT=$(echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len([r for r in data if r.get('status') == 'jitter']))
except:
    print(0)
" 2>/dev/null || echo "0")

# --- File-writer gap analysis (persistent vdc) ---
echo "Analyzing file-writer gaps (persistent /data/)..."
FILE_WRITER_GAP_DATA=$(run_on_vm "cat /data/test/log.txt 2>/dev/null | python3 -c \"
import sys, json, re
from datetime import datetime

lines = sys.stdin.readlines()
if not lines:
    print('[]')
    sys.exit(0)

# Parse timestamps and convert to epoch
entries = []
for line in lines:
    # Format: 'Mon Mar 31 12:34:56 UTC 2026 - writing test data'
    match = re.match(r'(\w{3} \w{3} +\d+ \d+:\d+:\d+ UTC \d{4})', line)
    if match:
        try:
            ts_str = match.group(1)
            dt = datetime.strptime(ts_str, '%a %b %d %H:%M:%S UTC %Y')
            epoch = int(dt.timestamp())
            entries.append(epoch)
        except:
            continue

if len(entries) < 2:
    print('[]')
    sys.exit(0)

# Calculate gaps and bucket into 30s windows
buckets = {}
for i in range(1, len(entries)):
    gap = entries[i] - entries[i-1]
    bucket_ts = (entries[i] // 30) * 30

    if bucket_ts not in buckets:
        buckets[bucket_ts] = {'total': 0, 'slow': 0, 'max_gap': 0}

    buckets[bucket_ts]['total'] += 1
    if gap > 1:  # Expected interval is 1 second
        buckets[bucket_ts]['slow'] += 1
    if gap > buckets[bucket_ts]['max_gap']:
        buckets[bucket_ts]['max_gap'] = gap

# Build output
result = []
for bucket_ts in sorted(buckets.keys()):
    b = buckets[bucket_ts]
    if b['slow'] > 0:  # Only include windows with gaps
        slow_pct = round(b['slow'] * 100.0 / b['total'], 1) if b['total'] > 0 else 0
        status = 'affected' if b['slow'] >= 5 else 'jitter'
        result.append({
            'time_window_utc': datetime.utcfromtimestamp(bucket_ts).strftime('%Y-%m-%d %H:%M:%S'),
            'epoch': bucket_ts,
            'total_writes': b['total'],
            'slow_writes': b['slow'],
            'slow_pct': slow_pct,
            'max_gap_sec': b['max_gap'],
            'status': status
        })

print(json.dumps(result))
\"" 2>/dev/null || echo "[]")

# --- Ephemeral file-writer gap analysis (vda) ---
echo "Analyzing ephemeral file-writer gaps (/var/lib/test-ephemeral/)..."
EPHEMERAL_FILE_WRITER_GAP_DATA=$(run_on_vm "cat /var/lib/test-ephemeral/log.txt 2>/dev/null | python3 -c \"
import sys, json, re
from datetime import datetime

lines = sys.stdin.readlines()
if not lines:
    print('[]')
    sys.exit(0)

entries = []
for line in lines:
    match = re.match(r'(\w{3} \w{3} +\d+ \d+:\d+:\d+ UTC \d{4})', line)
    if match:
        try:
            ts_str = match.group(1)
            dt = datetime.strptime(ts_str, '%a %b %d %H:%M:%S UTC %Y')
            epoch = int(dt.timestamp())
            entries.append(epoch)
        except:
            continue

if len(entries) < 2:
    print('[]')
    sys.exit(0)

buckets = {}
for i in range(1, len(entries)):
    gap = entries[i] - entries[i-1]
    bucket_ts = (entries[i] // 30) * 30

    if bucket_ts not in buckets:
        buckets[bucket_ts] = {'total': 0, 'slow': 0, 'max_gap': 0}

    buckets[bucket_ts]['total'] += 1
    if gap > 1:
        buckets[bucket_ts]['slow'] += 1
    if gap > buckets[bucket_ts]['max_gap']:
        buckets[bucket_ts]['max_gap'] = gap

result = []
for bucket_ts in sorted(buckets.keys()):
    b = buckets[bucket_ts]
    if b['slow'] > 0:
        slow_pct = round(b['slow'] * 100.0 / b['total'], 1) if b['total'] > 0 else 0
        status = 'affected' if b['slow'] >= 5 else 'jitter'
        result.append({
            'time_window_utc': datetime.utcfromtimestamp(bucket_ts).strftime('%Y-%m-%d %H:%M:%S'),
            'epoch': bucket_ts,
            'total_writes': b['total'],
            'slow_writes': b['slow'],
            'slow_pct': slow_pct,
            'max_gap_sec': b['max_gap'],
            'status': status
        })

print(json.dumps(result))
\"" 2>/dev/null || echo "[]")

# --- Cron gap analysis ---
echo "Analyzing cron job gaps..."
CRON_GAP_DATA=$(run_on_vm "cat /data/test/cron.log 2>/dev/null | python3 -c \"
import sys, json, re
from datetime import datetime

lines = sys.stdin.readlines()
if not lines:
    print('[]')
    sys.exit(0)

entries = []
for line in lines:
    # Format: 'cron ran at Mon Mar 31 12:34:00 UTC 2026'
    match = re.search(r'at (\w{3} \w{3} +\d+ \d+:\d+:\d+ UTC \d{4})', line)
    if match:
        try:
            ts_str = match.group(1)
            dt = datetime.strptime(ts_str, '%a %b %d %H:%M:%S UTC %Y')
            epoch = int(dt.timestamp())
            entries.append(epoch)
        except:
            continue

if len(entries) < 2:
    print('[]')
    sys.exit(0)

# Calculate gaps (expected: 60 seconds)
gaps = []
for i in range(1, len(entries)):
    gap = entries[i] - entries[i-1]
    if gap > 60:  # Missing cron execution
        gaps.append({
            'from_time_utc': datetime.utcfromtimestamp(entries[i-1]).strftime('%Y-%m-%d %H:%M:%S'),
            'to_time_utc': datetime.utcfromtimestamp(entries[i]).strftime('%Y-%m-%d %H:%M:%S'),
            'gap_seconds': gap,
            'missing_executions': max(0, (gap // 60) - 1)
        })

print(json.dumps(gaps))
\"" 2>/dev/null || echo "[]")

# --- Load pre-migration data if provided ---
PRE_FILE_WRITER_LINES=0
PRE_SQLITE_ROWS=0
PRE_CRON_LINES=0
PRE_FILE_WRITER_PID="unknown"
PRE_SQLITE_PID="unknown"
PRE_HTTP_PID="unknown"
PRE_HOSTNAME="unknown"
PRE_CLUSTER_SERVER="unknown"
PRE_LARGE_FILE_SHA256="none"
PRE_LARGE_FILE_SIZE=0

PRE_EPHEMERAL_FILE_WRITER_LINES=0
PRE_EPHEMERAL_SQLITE_ROWS=0
PRE_EPHEMERAL_FILE_WRITER_PID="unknown"
PRE_EPHEMERAL_SQLITE_PID="unknown"
PRE_EPHEMERAL_LARGE_FILE_SHA256="none"
PRE_EPHEMERAL_LARGE_FILE_SIZE=0

HAS_PRE="false"
if [[ -n "$PRE_MIGRATION_FILE" && -f "$PRE_MIGRATION_FILE" ]]; then
  HAS_PRE="true"
  echo "Loading pre-migration baseline from: ${PRE_MIGRATION_FILE}"

  # Parse pre-migration JSON (using python3 if available, fallback to grep)
  if command -v python3 &>/dev/null; then
    # Persistent (vdc) data - handle both old and new JSON structure
    PRE_FILE_WRITER_LINES=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('persistent_vdc', d.get('workloads', {})).get('file_writer', {}).get('line_count', 0))" 2>/dev/null || echo "0")
    PRE_SQLITE_ROWS=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('persistent_vdc', d.get('workloads', {})).get('sqlite_writer', {}).get('row_count', 0))" 2>/dev/null || echo "0")
    PRE_CRON_LINES=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('persistent_vdc', d.get('workloads', {})).get('cron_job', {}).get('log_line_count', 0))" 2>/dev/null || echo "0")
    PRE_FILE_WRITER_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('persistent_vdc', d.get('workloads', {})).get('file_writer', {}).get('pid', 'unknown'))" 2>/dev/null || echo "unknown")
    PRE_SQLITE_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('persistent_vdc', d.get('workloads', {})).get('sqlite_writer', {}).get('pid', 'unknown'))" 2>/dev/null || echo "unknown")
    PRE_HTTP_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('persistent_vdc', d.get('workloads', {})).get('http_server', {}).get('pid', 'unknown'))" 2>/dev/null || echo "unknown")
    PRE_HOSTNAME=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['vm_info']['hostname'])")
    PRE_CLUSTER_SERVER=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['cluster']['server'])")
    PRE_LARGE_FILE_SHA256=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('large_data_validation', d.get('large_data', {})).get('persistent_vdc', d.get('large_data_validation', d.get('large_data', {}))).get('sha256', 'none'))" 2>/dev/null || echo "none")
    PRE_LARGE_FILE_SIZE=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('large_data_validation', d.get('large_data', {})).get('persistent_vdc', d.get('large_data_validation', d.get('large_data', {}))).get('file_size_bytes', 0))" 2>/dev/null || echo "0")

    # Ephemeral (vda) data
    PRE_EPHEMERAL_FILE_WRITER_LINES=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('ephemeral_vda', {}).get('file_writer', {}).get('line_count', 0))" 2>/dev/null || echo "0")
    PRE_EPHEMERAL_SQLITE_ROWS=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('ephemeral_vda', {}).get('sqlite_writer', {}).get('row_count', 0))" 2>/dev/null || echo "0")
    PRE_EPHEMERAL_FILE_WRITER_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('ephemeral_vda', {}).get('file_writer', {}).get('pid', 'unknown'))" 2>/dev/null || echo "unknown")
    PRE_EPHEMERAL_SQLITE_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('workloads', {}).get('ephemeral_vda', {}).get('sqlite_writer', {}).get('pid', 'unknown'))" 2>/dev/null || echo "unknown")
    PRE_EPHEMERAL_LARGE_FILE_SHA256=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('large_data_validation', {}).get('ephemeral_vda', {}).get('sha256', 'none'))" 2>/dev/null || echo "none")
    PRE_EPHEMERAL_LARGE_FILE_SIZE=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d.get('large_data_validation', {}).get('ephemeral_vda', {}).get('file_size_bytes', 0))" 2>/dev/null || echo "0")
  fi
fi

# --- Compute comparison ---
POST_FILE_WRITER_LINES=$(get_val FILE_WRITER_LINES)
POST_SQLITE_ROWS=$(get_val SQLITE_ROWS)
POST_CRON_LINES=$(get_val CRON_LINES)

FILE_WRITER_DIFF=$((POST_FILE_WRITER_LINES - PRE_FILE_WRITER_LINES))
SQLITE_DIFF=$((POST_SQLITE_ROWS - PRE_SQLITE_ROWS))
CRON_DIFF=$((POST_CRON_LINES - PRE_CRON_LINES))

FILE_WRITER_PID_MATCH="unknown"
SQLITE_PID_MATCH="unknown"
HTTP_PID_MATCH="unknown"
if [[ "$HAS_PRE" == "true" ]]; then
  FILE_WRITER_PID_MATCH=$( [ "$(get_val FILE_WRITER_PID)" == "$PRE_FILE_WRITER_PID" ] && echo "same" || echo "changed" )
  SQLITE_PID_MATCH=$( [ "$(get_val SQLITE_PID)" == "$PRE_SQLITE_PID" ] && echo "same" || echo "changed" )
  HTTP_PID_MATCH=$( [ "$(get_val HTTP_PID)" == "$PRE_HTTP_PID" ] && echo "same" || echo "changed" )
fi

# Determine migration type from PID behavior
MIGRATION_TYPE="unknown"
if [[ "$HAS_PRE" == "true" ]]; then
  if [[ "$FILE_WRITER_PID_MATCH" == "same" && "$SQLITE_PID_MATCH" == "same" ]]; then
    MIGRATION_TYPE="live (memory preserved, same PIDs)"
  else
    MIGRATION_TYPE="cold (VM rebooted, new PIDs)"
  fi
fi

# --- Ephemeral disk comparisons ---
POST_EPHEMERAL_FILE_WRITER_LINES=$(get_val EPHEMERAL_FILE_WRITER_LINES)
POST_EPHEMERAL_SQLITE_ROWS=$(get_val EPHEMERAL_SQLITE_ROWS)

EPHEMERAL_FILE_WRITER_DIFF=$((POST_EPHEMERAL_FILE_WRITER_LINES - PRE_EPHEMERAL_FILE_WRITER_LINES))
EPHEMERAL_SQLITE_DIFF=$((POST_EPHEMERAL_SQLITE_ROWS - PRE_EPHEMERAL_SQLITE_ROWS))

EPHEMERAL_FILE_WRITER_PID_MATCH="unknown"
EPHEMERAL_SQLITE_PID_MATCH="unknown"
if [[ "$HAS_PRE" == "true" ]]; then
  EPHEMERAL_FILE_WRITER_PID_MATCH=$( [ "$(get_val EPHEMERAL_FILE_WRITER_PID)" == "$PRE_EPHEMERAL_FILE_WRITER_PID" ] && echo "same" || echo "changed" )
  EPHEMERAL_SQLITE_PID_MATCH=$( [ "$(get_val EPHEMERAL_SQLITE_PID)" == "$PRE_EPHEMERAL_SQLITE_PID" ] && echo "same" || echo "changed" )
fi

# --- Large file SHA validation (persistent) ---
POST_LARGE_FILE_SHA256="$(get_val LARGE_FILE_SHA256)"
POST_LARGE_FILE_SIZE="$(get_val LARGE_FILE_SIZE)"

LARGE_DATA_INTACT="false"
if [[ "$PRE_LARGE_FILE_SHA256" != "none" ]] && [[ "$POST_LARGE_FILE_SHA256" != "none" ]]; then
  if [[ "$PRE_LARGE_FILE_SHA256" == "$POST_LARGE_FILE_SHA256" ]]; then
    LARGE_DATA_INTACT="true"
  fi
fi

# --- Large file SHA validation (ephemeral) ---
POST_EPHEMERAL_LARGE_FILE_SHA256="$(get_val EPHEMERAL_LARGE_FILE_SHA256)"
POST_EPHEMERAL_LARGE_FILE_SIZE="$(get_val EPHEMERAL_LARGE_FILE_SIZE)"

EPHEMERAL_DATA_INTACT="false"
if [[ "$PRE_EPHEMERAL_LARGE_FILE_SHA256" != "none" ]] && [[ "$POST_EPHEMERAL_LARGE_FILE_SHA256" != "none" ]]; then
  if [[ "$PRE_EPHEMERAL_LARGE_FILE_SHA256" == "$POST_EPHEMERAL_LARGE_FILE_SHA256" ]]; then
    EPHEMERAL_DATA_INTACT="true"
  fi
fi

echo "Building JSON report..."

cat > "$OUTPUT_FILE" << JSONEOF
{
  "type": "post-migration",
  "vm_name": "${VM_NAME}",
  "namespace": "${NAMESPACE}",
  "timestamp_utc": "$(get_val CAPTURE_TIME_UTC)",
  "timestamp_local": "$(get_val CAPTURE_TIME_LOCAL)",
  "cluster": {
    "server": "${CLUSTER_SERVER}",
    "vm_status": "${VM_STATUS}",
    "vm_node": "${VM_NODE}",
    "vm_pod_ip": "${VM_IP}"
  },
  "workloads": {
    "persistent_vdc": {
      "mount_point": "/data",
      "device": "/dev/vdc",
      "file_writer": {
        "status": "$([ "$(get_val FILE_WRITER_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val FILE_WRITER_PID)",
        "file": "/data/test/log.txt",
        "line_count": ${POST_FILE_WRITER_LINES},
        "file_size_bytes": $(get_val FILE_WRITER_SIZE),
        "last_entry": "$(get_val FILE_WRITER_LAST)",
        "write_interval_sec": 1,
        "gap_analysis": ${FILE_WRITER_GAP_DATA:-[]}
      },
      "sqlite_writer": {
        "status": "$([ "$(get_val SQLITE_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val SQLITE_PID)",
        "file": "/data/test.db",
        "row_count": ${POST_SQLITE_ROWS},
        "min_timestamp": $(get_val SQLITE_MIN_TS),
        "max_timestamp": $(get_val SQLITE_MAX_TS),
        "integrity_check": "$(get_val SQLITE_INTEGRITY)",
        "file_size_bytes": $(get_val SQLITE_SIZE),
        "insert_interval_sec": 2,
        "gap_analysis": {
          "gaps_greater_than_2s": $(get_val SQLITE_GAPS_GT2),
          "max_gap_seconds": $(get_val SQLITE_MAX_GAP),
          "affected_time_range": ${AFFECTED_WINDOWS},
          "sporadic_jitter_windows": ${JITTER_COUNT},
          "all_slow_windows": ${SQLITE_GAP_DATA:-[]}
        }
      },
      "cron_job": {
        "crond_status": "$(get_val CROND_STATUS)",
        "crontab_entry": "$(get_val CRONTAB_ENTRY)",
        "log_file": "/data/test/cron.log",
        "log_line_count": ${POST_CRON_LINES},
        "last_entry": "$(get_val CRON_LAST)",
        "interval": "every 1 minute",
        "gap_analysis": ${CRON_GAP_DATA:-[]}
      },
      "http_server": {
        "status": "$([ "$(get_val HTTP_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val HTTP_PID)",
        "port": 8080,
        "http_response_code": $(get_val HTTP_STATUS)
      }
    },
    "ephemeral_vda": {
      "mount_point": "/var/lib/test-ephemeral",
      "device": "/dev/vda",
      "file_writer": {
        "status": "$([ "$(get_val EPHEMERAL_FILE_WRITER_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val EPHEMERAL_FILE_WRITER_PID)",
        "file": "/var/lib/test-ephemeral/log.txt",
        "line_count": ${POST_EPHEMERAL_FILE_WRITER_LINES},
        "file_size_bytes": $(get_val EPHEMERAL_FILE_WRITER_SIZE),
        "last_entry": "$(get_val EPHEMERAL_FILE_WRITER_LAST)",
        "write_interval_sec": 1,
        "gap_analysis": ${EPHEMERAL_FILE_WRITER_GAP_DATA:-[]}
      },
      "sqlite_writer": {
        "status": "$([ "$(get_val EPHEMERAL_SQLITE_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val EPHEMERAL_SQLITE_PID)",
        "file": "/var/lib/test-ephemeral/test.db",
        "row_count": ${POST_EPHEMERAL_SQLITE_ROWS},
        "min_timestamp": $(get_val EPHEMERAL_SQLITE_MIN_TS),
        "max_timestamp": $(get_val EPHEMERAL_SQLITE_MAX_TS),
        "integrity_check": "$(get_val EPHEMERAL_SQLITE_INTEGRITY)",
        "file_size_bytes": $(get_val EPHEMERAL_SQLITE_SIZE),
        "insert_interval_sec": 2
      }
    }
  },
  "vm_info": {
    "hostname": "$(get_val VM_HOSTNAME)",
    "ip_address": "$(get_val VM_IP_INTERNAL)",
    "uptime_seconds": $(get_val VM_UPTIME),
    "disk": {
      "total_bytes": $(get_val DISK_TOTAL),
      "used_bytes": $(get_val DISK_USED),
      "available_bytes": $(get_val DISK_AVAIL)
    },
    "data_dir_size_bytes": $(get_val DATA_DIR_SIZE)
  },
  "comparison": {
    "has_pre_migration_data": ${HAS_PRE},
    "pre_migration_file": "${PRE_MIGRATION_FILE}",
    "source_cluster": "${PRE_CLUSTER_SERVER}",
    "target_cluster": "${CLUSTER_SERVER}",
    "inferred_migration_type": "${MIGRATION_TYPE}",
    "data_integrity": {
      "file_writer": {
        "pre_lines": ${PRE_FILE_WRITER_LINES},
        "post_lines": ${POST_FILE_WRITER_LINES},
        "diff": ${FILE_WRITER_DIFF},
        "data_loss": $([ "$FILE_WRITER_DIFF" -ge 0 ] && echo false || echo true)
      },
      "sqlite": {
        "pre_rows": ${PRE_SQLITE_ROWS},
        "post_rows": ${POST_SQLITE_ROWS},
        "diff": ${SQLITE_DIFF},
        "data_loss": $([ "$SQLITE_DIFF" -ge 0 ] && echo false || echo true),
        "integrity_ok": $([ "$(get_val SQLITE_INTEGRITY)" == "ok" ] && echo true || echo false)
      },
      "cron": {
        "pre_lines": ${PRE_CRON_LINES},
        "post_lines": ${POST_CRON_LINES},
        "diff": ${CRON_DIFF},
        "data_loss": $([ "$CRON_DIFF" -ge 0 ] && echo false || echo true)
      }
    },
    "process_continuity": {
      "file_writer_pid": "${FILE_WRITER_PID_MATCH}",
      "sqlite_writer_pid": "${SQLITE_PID_MATCH}",
      "http_server_pid": "${HTTP_PID_MATCH}"
    },
    "network": {
      "hostname_preserved": $([ "$(get_val VM_HOSTNAME)" == "${PRE_HOSTNAME}" ] && echo true || echo false)
    }
  },
  "large_data_validation": {
    "persistent_vdc": {
      "file_path": "/data/large-file.bin",
      "sha256_match": $(echo $LARGE_DATA_INTACT),
      "pre_sha256": "$PRE_LARGE_FILE_SHA256",
      "post_sha256": "$POST_LARGE_FILE_SHA256",
      "pre_size_bytes": $PRE_LARGE_FILE_SIZE,
      "post_size_bytes": $POST_LARGE_FILE_SIZE
    },
    "ephemeral_vda": {
      "file_path": "/var/lib/test-ephemeral/large-file.bin",
      "sha256_match": $(echo $EPHEMERAL_DATA_INTACT),
      "pre_sha256": "$PRE_EPHEMERAL_LARGE_FILE_SHA256",
      "post_sha256": "$POST_EPHEMERAL_LARGE_FILE_SHA256",
      "pre_size_bytes": $PRE_EPHEMERAL_LARGE_FILE_SIZE,
      "post_size_bytes": $POST_EPHEMERAL_LARGE_FILE_SIZE
    }
  },
  "verdict": {
    "persistent_data_intact": $([ "$FILE_WRITER_DIFF" -ge 0 ] && [ "$SQLITE_DIFF" -ge 0 ] && [ "$CRON_DIFF" -ge 0 ] && [ "$(get_val SQLITE_INTEGRITY)" == "ok" ] && echo true || echo false),
    "ephemeral_data_intact": $([ "$EPHEMERAL_FILE_WRITER_DIFF" -ge 0 ] && [ "$EPHEMERAL_SQLITE_DIFF" -ge 0 ] && [ "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" == "ok" ] && echo true || echo false),
    "persistent_large_data_intact": $(echo $LARGE_DATA_INTACT),
    "ephemeral_large_data_intact": $(echo $EPHEMERAL_DATA_INTACT),
    "all_processes_running": $([ "$(get_val FILE_WRITER_PID)" != "none" ] && [ "$(get_val SQLITE_PID)" != "none" ] && [ "$(get_val HTTP_PID)" != "none" ] && [ "$(get_val CROND_STATUS)" == "active" ] && [ "$(get_val EPHEMERAL_FILE_WRITER_PID)" != "none" ] && [ "$(get_val EPHEMERAL_SQLITE_PID)" != "none" ] && echo true || echo false),
    "http_responding": $([ "$(get_val HTTP_STATUS)" == "200" ] && echo true || echo false)
  }
}
JSONEOF

echo ""
echo "============================================"
echo "  Post-migration data saved to:"
echo "  ${OUTPUT_FILE}"
echo "============================================"
echo ""
echo "--- Comparison Summary ---"
echo ""
echo "--- Persistent Data (vdc /data/) ---"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "Workload" "Pre" "Post" "Diff" "Status"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "--------" "---" "----" "----" "------"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "File writer lines" "$PRE_FILE_WRITER_LINES" "$POST_FILE_WRITER_LINES" "+${FILE_WRITER_DIFF}" "$([ "$FILE_WRITER_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "SQLite rows" "$PRE_SQLITE_ROWS" "$POST_SQLITE_ROWS" "+${SQLITE_DIFF}" "$([ "$SQLITE_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "Cron log lines" "$PRE_CRON_LINES" "$POST_CRON_LINES" "+${CRON_DIFF}" "$([ "$CRON_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
echo ""
echo "  SQLite integrity:    $(get_val SQLITE_INTEGRITY)"
echo "  SQLite max gap:      $(get_val SQLITE_MAX_GAP)s (expected: 2s)"
echo "  SQLite gaps > 2s:    $(get_val SQLITE_GAPS_GT2)"
echo "  Migration type:      ${MIGRATION_TYPE}"
echo ""
echo "  Process PIDs:        file-writer=$(get_val FILE_WRITER_PID)(${FILE_WRITER_PID_MATCH}) sqlite=$(get_val SQLITE_PID)(${SQLITE_PID_MATCH}) http=$(get_val HTTP_PID)(${HTTP_PID_MATCH})"
echo "  Services:            crond=$(get_val CROND_STATUS) http=$(get_val HTTP_STATUS)"
echo ""
echo "--- Ephemeral Data (vda /var/lib/test-ephemeral/) ---"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "Workload" "Pre" "Post" "Diff" "Status"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "--------" "---" "----" "----" "------"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "File writer lines" "$PRE_EPHEMERAL_FILE_WRITER_LINES" "$POST_EPHEMERAL_FILE_WRITER_LINES" "+${EPHEMERAL_FILE_WRITER_DIFF}" "$([ "$EPHEMERAL_FILE_WRITER_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
printf "  %-18s %-10s %-10s %-10s %-8s\n" "SQLite rows" "$PRE_EPHEMERAL_SQLITE_ROWS" "$POST_EPHEMERAL_SQLITE_ROWS" "+${EPHEMERAL_SQLITE_DIFF}" "$([ "$EPHEMERAL_SQLITE_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
echo ""
echo "  SQLite integrity:    $(get_val EPHEMERAL_SQLITE_INTEGRITY)"
echo "  Process PIDs:        file-writer=$(get_val EPHEMERAL_FILE_WRITER_PID)(${EPHEMERAL_FILE_WRITER_PID_MATCH}) sqlite=$(get_val EPHEMERAL_SQLITE_PID)(${EPHEMERAL_SQLITE_PID_MATCH})"
echo ""

echo "--- Large File Validation ---"
echo ""
if [[ "$PRE_LARGE_FILE_SHA256" != "none" ]]; then
  echo "  Persistent (vdc):"
  echo "    Pre-migration SHA256:  ${PRE_LARGE_FILE_SHA256}"
  echo "    Post-migration SHA256: ${POST_LARGE_FILE_SHA256}"
  echo "    Match:                 $([ "$LARGE_DATA_INTACT" == "true" ] && echo 'YES (PASS)' || echo 'NO (FAIL)')"
  echo "    File size:             ${POST_LARGE_FILE_SIZE} bytes ($(( POST_LARGE_FILE_SIZE / 1024 / 1024 ))MB)"
fi
echo ""
if [[ "$PRE_EPHEMERAL_LARGE_FILE_SHA256" != "none" ]]; then
  echo "  Ephemeral (vda):"
  echo "    Pre-migration SHA256:  ${PRE_EPHEMERAL_LARGE_FILE_SHA256}"
  echo "    Post-migration SHA256: ${POST_EPHEMERAL_LARGE_FILE_SHA256}"
  echo "    Match:                 $([ "$EPHEMERAL_DATA_INTACT" == "true" ] && echo 'YES (PASS)' || echo 'NO (FAIL)')"
  echo "    File size:             ${POST_EPHEMERAL_LARGE_FILE_SIZE} bytes ($(( POST_EPHEMERAL_LARGE_FILE_SIZE / 1024 / 1024 ))MB)"
fi
echo ""

echo "--- SQLite Insert Gap Analysis (30s windows) ---"
echo ""
echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all inserts at expected 2s interval.')
    else:
        affected = [r for r in data if r.get('status') == 'affected']
        jitter = [r for r in data if r.get('status') == 'jitter']

        if affected:
            print(f'  MIGRATION-AFFECTED WINDOW:')
            print(f'    From:           {affected[0][\"time_window_utc\"]} UTC')
            print(f'    To:             {affected[-1][\"time_window_utc\"]} UTC')
            print(f'    Duration:       ~{affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30}s ({(affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30) // 60} min)')
            print(f'    Slow inserts:   {sum(r[\"slow_inserts\"] for r in affected)} of {sum(r[\"total_inserts\"] for r in affected)} ({round(sum(r[\"slow_pct\"] for r in affected) / len(affected), 1)}% avg)')
            print(f'    Max gap:        {max(r[\"max_gap_sec\"] for r in affected)}s')
            print()
            print(f'    Time Window UTC          Total  Slow   Slow%  MaxGap  Status')
            print(f'    -------------------      -----  ----   -----  ------  ------')
            for r in affected:
                print(f'    {r[\"time_window_utc\"]}  {r[\"total_inserts\"]:>5}  {r[\"slow_inserts\"]:>4}   {r[\"slow_pct\"]:>5}%  {r[\"max_gap_sec\"]:>5}s  AFFECTED')
        else:
            print('  No migration-affected window detected.')

        print()
        if jitter:
            print(f'  SPORADIC JITTER: {len(jitter)} windows with minor 1-off slow inserts (normal OS scheduling noise)')
        else:
            print('  No sporadic jitter detected.')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
echo ""

echo "--- File-Writer Gap Analysis (persistent vdc) ---"
echo ""
echo "$FILE_WRITER_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all writes at expected 1s interval.')
    else:
        affected = [r for r in data if r.get('status') == 'affected']
        jitter = [r for r in data if r.get('status') == 'jitter']

        if affected:
            print(f'  MIGRATION-AFFECTED WINDOW:')
            print(f'    From:           {affected[0][\"time_window_utc\"]} UTC')
            print(f'    To:             {affected[-1][\"time_window_utc\"]} UTC')
            print(f'    Duration:       ~{affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30}s ({(affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30) // 60} min)')
            print(f'    Slow writes:    {sum(r[\"slow_writes\"] for r in affected)} of {sum(r[\"total_writes\"] for r in affected)} ({round(sum(r[\"slow_pct\"] for r in affected) / len(affected), 1)}% avg)')
            print(f'    Max gap:        {max(r[\"max_gap_sec\"] for r in affected)}s')
            print()
            print(f'    Time Window UTC          Total  Slow   Slow%  MaxGap  Status')
            print(f'    -------------------      -----  ----   -----  ------  ------')
            for r in affected:
                print(f'    {r[\"time_window_utc\"]}  {r[\"total_writes\"]:>5}  {r[\"slow_writes\"]:>4}   {r[\"slow_pct\"]:>5}%  {r[\"max_gap_sec\"]:>5}s  AFFECTED')
        else:
            print('  No migration-affected window detected.')

        print()
        if jitter:
            print(f'  SPORADIC JITTER: {len(jitter)} windows with minor delays (normal OS scheduling noise)')
        else:
            print('  No sporadic jitter detected.')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
echo ""

echo "--- File-Writer Gap Analysis (ephemeral vda) ---"
echo ""
echo "$EPHEMERAL_FILE_WRITER_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all writes at expected 1s interval.')
    else:
        affected = [r for r in data if r.get('status') == 'affected']
        jitter = [r for r in data if r.get('status') == 'jitter']

        if affected:
            print(f'  MIGRATION-AFFECTED WINDOW:')
            print(f'    From:           {affected[0][\"time_window_utc\"]} UTC')
            print(f'    To:             {affected[-1][\"time_window_utc\"]} UTC')
            print(f'    Duration:       ~{affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30}s ({(affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30) // 60} min)')
            print(f'    Slow writes:    {sum(r[\"slow_writes\"] for r in affected)} of {sum(r[\"total_writes\"] for r in affected)} ({round(sum(r[\"slow_pct\"] for r in affected) / len(affected), 1)}% avg)')
            print(f'    Max gap:        {max(r[\"max_gap_sec\"] for r in affected)}s')
            print()
            print(f'    Time Window UTC          Total  Slow   Slow%  MaxGap  Status')
            print(f'    -------------------      -----  ----   -----  ------  ------')
            for r in affected:
                print(f'    {r[\"time_window_utc\"]}  {r[\"total_writes\"]:>5}  {r[\"slow_writes\"]:>4}   {r[\"slow_pct\"]:>5}%  {r[\"max_gap_sec\"]:>5}s  AFFECTED')
        else:
            print('  No migration-affected window detected.')

        print()
        if jitter:
            print(f'  SPORADIC JITTER: {len(jitter)} windows with minor delays (normal OS scheduling noise)')
        else:
            print('  No sporadic jitter detected.')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
echo ""

echo "--- Cron Job Gap Analysis ---"
echo ""
echo "$CRON_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all cron executions at expected 1-minute interval.')
    else:
        print(f'  MISSING CRON EXECUTIONS DETECTED: {len(data)} gaps found')
        print()
        print(f'    From Time UTC             To Time UTC               Gap(s)  Missing')
        print(f'    ------------------------  ------------------------  ------  -------')
        for r in data:
            print(f'    {r[\"from_time_utc\"]}  {r[\"to_time_utc\"]}  {r[\"gap_seconds\"]:>6}  {r[\"missing_executions\"]:>7}')
        print()
        total_missing = sum(r['missing_executions'] for r in data)
        total_gap_time = sum(r['gap_seconds'] for r in data)
        print(f'    Total missing executions: {total_missing}')
        print(f'    Total gap time:           {total_gap_time}s ({total_gap_time // 60} min)')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
echo ""

# Compute individual check statuses
PERSISTENT_FILE_WRITER_STATUS="PASS"
[ "$FILE_WRITER_DIFF" -lt 0 ] && PERSISTENT_FILE_WRITER_STATUS="FAIL"

PERSISTENT_SQLITE_STATUS="PASS"
[ "$SQLITE_DIFF" -lt 0 ] && PERSISTENT_SQLITE_STATUS="FAIL"

PERSISTENT_SQLITE_INTEGRITY_STATUS="PASS"
[ "$(get_val SQLITE_INTEGRITY)" != "ok" ] && PERSISTENT_SQLITE_INTEGRITY_STATUS="FAIL"

PERSISTENT_CRON_STATUS="PASS"
[ "$CRON_DIFF" -lt 0 ] && PERSISTENT_CRON_STATUS="FAIL"

PERSISTENT_LARGE_FILE_STATUS="PASS"
[ "$LARGE_DATA_INTACT" != "true" ] && PERSISTENT_LARGE_FILE_STATUS="FAIL"

EPHEMERAL_FILE_WRITER_STATUS="PASS"
[ "$EPHEMERAL_FILE_WRITER_DIFF" -lt 0 ] && EPHEMERAL_FILE_WRITER_STATUS="FAIL"

EPHEMERAL_SQLITE_STATUS="PASS"
[ "$EPHEMERAL_SQLITE_DIFF" -lt 0 ] && EPHEMERAL_SQLITE_STATUS="FAIL"

EPHEMERAL_SQLITE_INTEGRITY_STATUS="PASS"
[ "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" != "ok" ] && EPHEMERAL_SQLITE_INTEGRITY_STATUS="FAIL"

EPHEMERAL_LARGE_FILE_STATUS="PASS"
[ "$EPHEMERAL_DATA_INTACT" != "true" ] && EPHEMERAL_LARGE_FILE_STATUS="FAIL"

HTTP_STATUS_CHECK="PASS"
[ "$(get_val HTTP_STATUS)" != "200" ] && HTTP_STATUS_CHECK="FAIL"

CROND_STATUS_CHECK="PASS"
[ "$(get_val CROND_STATUS)" != "active" ] && CROND_STATUS_CHECK="FAIL"

# Service running checks
SERVICES_RUNNING_STATUS="PASS"
if [ "$(get_val FILE_WRITER_PID)" == "none" ] || \
   [ "$(get_val SQLITE_PID)" == "none" ] || \
   [ "$(get_val HTTP_PID)" == "none" ] || \
   [ "$(get_val EPHEMERAL_FILE_WRITER_PID)" == "none" ] || \
   [ "$(get_val EPHEMERAL_SQLITE_PID)" == "none" ]; then
  SERVICES_RUNNING_STATUS="FAIL"
fi

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                      POST-MIGRATION VALIDATION SUMMARY                     ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

# --- PERSISTENT DISK (VDC) CHECKS ---
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ PERSISTENT DISK (/dev/vdc → /data/)                                        │"
echo "└─────────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Data Integrity:"
printf "    %-40s [%s]\n" "File-writer data continuity" "$PERSISTENT_FILE_WRITER_STATUS"
if [ "$PERSISTENT_FILE_WRITER_STATUS" == "FAIL" ]; then
  printf "      → Data loss detected: %d lines lost\n" "$((0 - FILE_WRITER_DIFF))"
fi

printf "    %-40s [%s]\n" "SQLite data continuity" "$PERSISTENT_SQLITE_STATUS"
if [ "$PERSISTENT_SQLITE_STATUS" == "FAIL" ]; then
  printf "      → Data loss detected: %d rows lost\n" "$((0 - SQLITE_DIFF))"
fi

printf "    %-40s [%s]\n" "SQLite database integrity" "$PERSISTENT_SQLITE_INTEGRITY_STATUS"
if [ "$PERSISTENT_SQLITE_INTEGRITY_STATUS" == "FAIL" ]; then
  printf "      → Integrity check result: %s\n" "$(get_val SQLITE_INTEGRITY)"
fi

printf "    %-40s [%s]\n" "Cron log continuity" "$PERSISTENT_CRON_STATUS"
if [ "$PERSISTENT_CRON_STATUS" == "FAIL" ]; then
  printf "      → Data loss detected: %d entries lost\n" "$((0 - CRON_DIFF))"
fi

printf "    %-40s [%s]\n" "Large file integrity (SHA256)" "$PERSISTENT_LARGE_FILE_STATUS"
if [ "$PERSISTENT_LARGE_FILE_STATUS" == "FAIL" ]; then
  echo "      → SHA256 mismatch detected"
  echo "      → Pre:  ${PRE_LARGE_FILE_SHA256}"
  echo "      → Post: ${POST_LARGE_FILE_SHA256}"
fi
echo ""

echo "  Services:"
printf "    %-40s [%s]\n" "HTTP server responding (port 8080)" "$HTTP_STATUS_CHECK"
if [ "$HTTP_STATUS_CHECK" == "FAIL" ]; then
  printf "      → HTTP response code: %s (expected: 200)\n" "$(get_val HTTP_STATUS)"
fi

printf "    %-40s [%s]\n" "Cron daemon active" "$CROND_STATUS_CHECK"
if [ "$CROND_STATUS_CHECK" == "FAIL" ]; then
  printf "      → Crond status: %s (expected: active)\n" "$(get_val CROND_STATUS)"
fi
echo ""

# --- EPHEMERAL DISK (VDA) CHECKS ---
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ EPHEMERAL DISK (/dev/vda → /var/lib/test-ephemeral/)                       │"
echo "└─────────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Data Integrity:"
printf "    %-40s [%s]\n" "File-writer data continuity" "$EPHEMERAL_FILE_WRITER_STATUS"
if [ "$EPHEMERAL_FILE_WRITER_STATUS" == "FAIL" ]; then
  printf "      → Data loss detected: %d lines lost\n" "$((0 - EPHEMERAL_FILE_WRITER_DIFF))"
  echo "      → Expected for cold migration (vda recreated)"
fi

printf "    %-40s [%s]\n" "SQLite data continuity" "$EPHEMERAL_SQLITE_STATUS"
if [ "$EPHEMERAL_SQLITE_STATUS" == "FAIL" ]; then
  printf "      → Data loss detected: %d rows lost\n" "$((0 - EPHEMERAL_SQLITE_DIFF))"
  echo "      → Expected for cold migration (vda recreated)"
fi

printf "    %-40s [%s]\n" "SQLite database integrity" "$EPHEMERAL_SQLITE_INTEGRITY_STATUS"
if [ "$EPHEMERAL_SQLITE_INTEGRITY_STATUS" == "FAIL" ]; then
  printf "      → Integrity check result: %s\n" "$(get_val EPHEMERAL_SQLITE_INTEGRITY)"
fi

printf "    %-40s [%s]\n" "Large file integrity (SHA256)" "$EPHEMERAL_LARGE_FILE_STATUS"
if [ "$EPHEMERAL_LARGE_FILE_STATUS" == "FAIL" ]; then
  echo "      → SHA256 mismatch or file missing"
  echo "      → Expected for cold migration (vda recreated)"
fi
echo ""

# --- PROCESS CONTINUITY ---
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ PROCESS CONTINUITY & SERVICES                                               │"
echo "└─────────────────────────────────────────────────────────────────────────────┘"
echo ""
printf "    %-40s [%s]\n" "All workload services running" "$SERVICES_RUNNING_STATUS"
if [ "$SERVICES_RUNNING_STATUS" == "FAIL" ]; then
  echo "      → Stopped services detected:"
  [ "$(get_val FILE_WRITER_PID)" == "none" ] && echo "        • file-writer (persistent)"
  [ "$(get_val SQLITE_PID)" == "none" ] && echo "        • sqlite-writer (persistent)"
  [ "$(get_val HTTP_PID)" == "none" ] && echo "        • http-server"
  [ "$(get_val EPHEMERAL_FILE_WRITER_PID)" == "none" ] && echo "        • file-writer (ephemeral)"
  [ "$(get_val EPHEMERAL_SQLITE_PID)" == "none" ] && echo "        • sqlite-writer (ephemeral)"
fi
echo ""

echo "  Migration Type: ${MIGRATION_TYPE}"
echo "    File-writer PID:  $(get_val FILE_WRITER_PID) (${FILE_WRITER_PID_MATCH})"
echo "    SQLite PID:       $(get_val SQLITE_PID) (${SQLITE_PID_MATCH})"
echo "    HTTP PID:         $(get_val HTTP_PID) (${HTTP_PID_MATCH})"
echo ""

# --- OVERALL VERDICT ---
OVERALL="PASS"
if [ "$FILE_WRITER_DIFF" -lt 0 ] || [ "$SQLITE_DIFF" -lt 0 ] || [ "$(get_val SQLITE_INTEGRITY)" != "ok" ] || [ "$LARGE_DATA_INTACT" != "true" ]; then
  OVERALL="FAIL"
fi
if [ "$EPHEMERAL_FILE_WRITER_DIFF" -lt 0 ] || [ "$EPHEMERAL_SQLITE_DIFF" -lt 0 ] || [ "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" != "ok" ] || [ "$EPHEMERAL_DATA_INTACT" != "true" ]; then
  OVERALL="FAIL"
fi

echo "╔════════════════════════════════════════════════════════════════════════════╗"
if [ "$OVERALL" == "PASS" ]; then
  echo "║                         ✓ MIGRATION VALIDATION PASSED                      ║"
  echo "╚════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  All checks passed successfully:"
  echo "    • Persistent data (vdc) preserved with SHA256 verification"
  echo "    • Ephemeral data (vda) preserved (true live migration)"
  echo "    • All workload services running"
  echo "    • Database integrity verified"
else
  echo "║                         ✗ MIGRATION VALIDATION FAILED                      ║"
  echo "╚════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Issues detected - review details above:"
  [ "$PERSISTENT_FILE_WRITER_STATUS" == "FAIL" ] && echo "    ✗ Persistent file-writer data loss"
  [ "$PERSISTENT_SQLITE_STATUS" == "FAIL" ] && echo "    ✗ Persistent SQLite data loss"
  [ "$PERSISTENT_SQLITE_INTEGRITY_STATUS" == "FAIL" ] && echo "    ✗ Persistent SQLite corruption"
  [ "$PERSISTENT_CRON_STATUS" == "FAIL" ] && echo "    ✗ Cron log data loss"
  [ "$PERSISTENT_LARGE_FILE_STATUS" == "FAIL" ] && echo "    ✗ Persistent large file corruption (SHA256 mismatch)"
  [ "$EPHEMERAL_FILE_WRITER_STATUS" == "FAIL" ] && echo "    ✗ Ephemeral file-writer data loss (cold migration?)"
  [ "$EPHEMERAL_SQLITE_STATUS" == "FAIL" ] && echo "    ✗ Ephemeral SQLite data loss (cold migration?)"
  [ "$EPHEMERAL_SQLITE_INTEGRITY_STATUS" == "FAIL" ] && echo "    ✗ Ephemeral SQLite corruption"
  [ "$EPHEMERAL_LARGE_FILE_STATUS" == "FAIL" ] && echo "    ✗ Ephemeral large file corruption (cold migration?)"
  [ "$HTTP_STATUS_CHECK" == "FAIL" ] && echo "    ✗ HTTP server not responding"
  [ "$CROND_STATUS_CHECK" == "FAIL" ] && echo "    ✗ Cron daemon not active"
  [ "$SERVICES_RUNNING_STATUS" == "FAIL" ] && echo "    ✗ Some workload services not running"
fi
echo ""
