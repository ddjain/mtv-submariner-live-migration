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

usage() {
  echo "Usage: $0 --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--ssh-user <user>] [--output-dir <dir>] [--pre-migration-file <path>] [--local-ssh-opts <opts>]"
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
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]] && { echo "ERROR: --vm is required"; usage; }

export KUBECONFIG="$KUBECONFIG_PATH"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTPUT_FILE="${OUTPUT_DIR}/post-migration-${VM_NAME}-${TIMESTAMP}.json"

run_on_vm() {
  if [[ -n "${LOCAL_SSH_OPTS}" ]]; then
    virtctl ssh "${SSH_USER}@vm/${VM_NAME}" \
      --namespace "$NAMESPACE" \
      --identity-file="$SSH_KEY" \
      --local-ssh-opts "$LOCAL_SSH_OPTS" \
      --command "$1"
  else
    virtctl ssh "${SSH_USER}@vm/${VM_NAME}" \
      --namespace "$NAMESPACE" \
      --identity-file="$SSH_KEY" \
      --command "$1"
  fi
}

echo "============================================"
echo "  Post-Migration Check: ${VM_NAME}"
echo "  Timestamp: ${TIMESTAMP}"
echo "============================================"
echo ""

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

# --- Load pre-migration data if provided ---
PRE_FILE_WRITER_LINES=0
PRE_SQLITE_ROWS=0
PRE_CRON_LINES=0
PRE_FILE_WRITER_PID="unknown"
PRE_SQLITE_PID="unknown"
PRE_HTTP_PID="unknown"
PRE_HOSTNAME="unknown"
PRE_CLUSTER_SERVER="unknown"

HAS_PRE="false"
if [[ -n "$PRE_MIGRATION_FILE" && -f "$PRE_MIGRATION_FILE" ]]; then
  HAS_PRE="true"
  echo "Loading pre-migration baseline from: ${PRE_MIGRATION_FILE}"

  # Parse pre-migration JSON (using python3 if available, fallback to grep)
  if command -v python3 &>/dev/null; then
    PRE_FILE_WRITER_LINES=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['workloads']['file_writer']['line_count'])")
    PRE_SQLITE_ROWS=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['workloads']['sqlite_writer']['row_count'])")
    PRE_CRON_LINES=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['workloads']['cron_job']['log_line_count'])")
    PRE_FILE_WRITER_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['workloads']['file_writer']['pid'])")
    PRE_SQLITE_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['workloads']['sqlite_writer']['pid'])")
    PRE_HTTP_PID=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['workloads']['http_server']['pid'])")
    PRE_HOSTNAME=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['vm_info']['hostname'])")
    PRE_CLUSTER_SERVER=$(python3 -c "import json; d=json.load(open('${PRE_MIGRATION_FILE}')); print(d['cluster']['server'])")
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
    "file_writer": {
      "status": "$([ "$(get_val FILE_WRITER_PID)" != "none" ] && echo running || echo stopped)",
      "pid": "$(get_val FILE_WRITER_PID)",
      "file": "/data/test/log.txt",
      "line_count": ${POST_FILE_WRITER_LINES},
      "file_size_bytes": $(get_val FILE_WRITER_SIZE),
      "last_entry": "$(get_val FILE_WRITER_LAST)",
      "write_interval_sec": 1
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
      "interval": "every 1 minute"
    },
    "http_server": {
      "status": "$([ "$(get_val HTTP_PID)" != "none" ] && echo running || echo stopped)",
      "pid": "$(get_val HTTP_PID)",
      "port": 8080,
      "http_response_code": $(get_val HTTP_STATUS)
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
  "verdict": {
    "data_intact": $([ "$FILE_WRITER_DIFF" -ge 0 ] && [ "$SQLITE_DIFF" -ge 0 ] && [ "$CRON_DIFF" -ge 0 ] && [ "$(get_val SQLITE_INTEGRITY)" == "ok" ] && echo true || echo false),
    "all_processes_running": $([ "$(get_val FILE_WRITER_PID)" != "none" ] && [ "$(get_val SQLITE_PID)" != "none" ] && [ "$(get_val HTTP_PID)" != "none" ] && [ "$(get_val CROND_STATUS)" == "active" ] && echo true || echo false),
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

OVERALL="PASS"
if [ "$FILE_WRITER_DIFF" -lt 0 ] || [ "$SQLITE_DIFF" -lt 0 ] || [ "$(get_val SQLITE_INTEGRITY)" != "ok" ]; then
  OVERALL="FAIL"
fi
echo "  Overall verdict:     ${OVERALL}"
echo ""
