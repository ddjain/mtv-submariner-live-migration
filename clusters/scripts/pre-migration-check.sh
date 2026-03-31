#!/usr/bin/env bash
set -euo pipefail

#
# Pre-migration checklist: captures baseline state of VM workloads as JSON.
# Output file: pre-migration-<vm>-<timestamp>.json
#
# Usage:
#   ./pre-migration-check.sh --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--output-dir <dir>]
#
# Example:
#   ./pre-migration-check.sh \
#     --kubeconfig /path/to/kubeconfig \
#     --vm mercury-vm \
#     --output-dir /path/to/output
#

NAMESPACE="default"
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="centos"
VM_NAME=""
KUBECONFIG_PATH=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/reports"
LOCAL_SSH_OPTS=""
SSH_READY_TIMEOUT=300
SSH_READY_INTERVAL=10

usage() {
  echo "Usage: $0 --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--ssh-user <user>] [--output-dir <dir>] [--local-ssh-opts <opts>] [--ssh-ready-timeout SEC]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)      KUBECONFIG_PATH="$2"; shift 2 ;;
    --vm)              VM_NAME="$2"; shift 2 ;;
    --namespace)       NAMESPACE="$2"; shift 2 ;;
    --ssh-key)         SSH_KEY="$2"; shift 2 ;;
    --ssh-user)        SSH_USER="$2"; shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
    --local-ssh-opts)  LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout) SSH_READY_TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]] && { echo "ERROR: --vm is required"; usage; }

# Validate timeout parameters
if [[ -z "${SSH_READY_TIMEOUT:-}" ]] || ! [[ "${SSH_READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  SSH_READY_TIMEOUT=300
fi
if [[ -z "${SSH_READY_INTERVAL:-}" ]] || ! [[ "${SSH_READY_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${SSH_READY_INTERVAL}" -eq 0 ]]; then
  SSH_READY_INTERVAL=10
fi

# SSH options are now hardcoded in run_on_vm() function using two separate flags
# This ensures it works with both new and changed SSH host keys

export KUBECONFIG="$KUBECONFIG_PATH"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTPUT_FILE="${OUTPUT_DIR}/pre-migration-${VM_NAME}-${TIMESTAMP}.json"

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
echo "  Pre-Migration Check: ${VM_NAME}"
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
# Gather all data as key=value pairs for easy parsing
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

# Parse key=value pairs into variables
get_val() {
  echo "$VM_DATA" | grep "^${1}=" | head -1 | cut -d'=' -f2-
}

echo "Building JSON report..."

cat > "$OUTPUT_FILE" << JSONEOF
{
  "type": "pre-migration",
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
        "line_count": $(get_val FILE_WRITER_LINES),
        "file_size_bytes": $(get_val FILE_WRITER_SIZE),
        "last_entry": "$(get_val FILE_WRITER_LAST)",
        "write_interval_sec": 1
      },
      "sqlite_writer": {
        "status": "$([ "$(get_val SQLITE_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val SQLITE_PID)",
        "file": "/data/test.db",
        "row_count": $(get_val SQLITE_ROWS),
        "min_timestamp": $(get_val SQLITE_MIN_TS),
        "max_timestamp": $(get_val SQLITE_MAX_TS),
        "integrity_check": "$(get_val SQLITE_INTEGRITY)",
        "file_size_bytes": $(get_val SQLITE_SIZE),
        "insert_interval_sec": 2
      },
      "cron_job": {
        "crond_status": "$(get_val CROND_STATUS)",
        "crontab_entry": "$(get_val CRONTAB_ENTRY)",
        "log_file": "/data/test/cron.log",
        "log_line_count": $(get_val CRON_LINES),
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
    "ephemeral_vda": {
      "mount_point": "/var/lib/test-ephemeral",
      "device": "/dev/vda",
      "file_writer": {
        "status": "$([ "$(get_val EPHEMERAL_FILE_WRITER_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val EPHEMERAL_FILE_WRITER_PID)",
        "file": "/var/lib/test-ephemeral/log.txt",
        "line_count": $(get_val EPHEMERAL_FILE_WRITER_LINES),
        "file_size_bytes": $(get_val EPHEMERAL_FILE_WRITER_SIZE),
        "last_entry": "$(get_val EPHEMERAL_FILE_WRITER_LAST)",
        "write_interval_sec": 1
      },
      "sqlite_writer": {
        "status": "$([ "$(get_val EPHEMERAL_SQLITE_PID)" != "none" ] && echo running || echo stopped)",
        "pid": "$(get_val EPHEMERAL_SQLITE_PID)",
        "file": "/var/lib/test-ephemeral/test.db",
        "row_count": $(get_val EPHEMERAL_SQLITE_ROWS),
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
  "large_data_validation": {
    "persistent_vdc": {
      "file_path": "/data/large-file.bin",
      "file_size_bytes": $(get_val LARGE_FILE_SIZE),
      "sha256": "$(get_val LARGE_FILE_SHA256)"
    },
    "ephemeral_vda": {
      "file_path": "/var/lib/test-ephemeral/large-file.bin",
      "file_size_bytes": $(get_val EPHEMERAL_LARGE_FILE_SIZE),
      "sha256": "$(get_val EPHEMERAL_LARGE_FILE_SHA256)"
    }
  }
}
JSONEOF

echo ""
echo "============================================"
echo "  Pre-migration data saved to:"
echo "  ${OUTPUT_FILE}"
echo "============================================"
echo ""
echo "Quick summary:"
echo "  Persistent (vdc):"
echo "    File writer:  $(get_val FILE_WRITER_LINES) lines, PID $(get_val FILE_WRITER_PID)"
echo "    SQLite DB:    $(get_val SQLITE_ROWS) rows, integrity=$(get_val SQLITE_INTEGRITY)"
echo "    Cron log:     $(get_val CRON_LINES) entries, crond=$(get_val CROND_STATUS)"
echo "    HTTP server:  status=$(get_val HTTP_STATUS), PID $(get_val HTTP_PID)"
echo "  Ephemeral (vda):"
echo "    File writer:  $(get_val EPHEMERAL_FILE_WRITER_LINES) lines, PID $(get_val EPHEMERAL_FILE_WRITER_PID)"
echo "    SQLite DB:    $(get_val EPHEMERAL_SQLITE_ROWS) rows, integrity=$(get_val EPHEMERAL_SQLITE_INTEGRITY)"
