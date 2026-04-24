#!/usr/bin/env bash
#
# capture-prometheus-metrics.sh
#
# Queries Thanos/Prometheus and VMIM CRs to collect live-migration
# observability data: dirty rate, transfer rate, data volumes,
# phase timings, VM resource usage, and MTV-level metrics.
#
# Designed to run standalone or be called from run-e2e.sh.
#
set -euo pipefail

SOURCE_KUBECONFIG=""
VM_NAME=""
NAMESPACE="default"
START_EPOCH=""
END_EPOCH=""
OUTPUT_FILE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Query Prometheus/Thanos and VMIM CRs for live-migration metrics.

Required:
  --source-kubeconfig PATH   Kubeconfig for source cluster (used for Thanos route + SA token)
  --vm NAME                  VM name to query metrics for
  --start-epoch SEC          Migration start time (unix epoch)
  --end-epoch SEC            Migration end time (unix epoch)

Optional:
  --namespace NS             Namespace (default: default)
  --output-file PATH         Write JSON to file (default: stdout)

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-kubeconfig) SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --vm)                VM_NAME="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --start-epoch)       START_EPOCH="$2"; shift 2 ;;
    --end-epoch)         END_EPOCH="$2"; shift 2 ;;
    --output-file)       OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *)                   echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SOURCE_KUBECONFIG" ]] && { echo "ERROR: --source-kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]]          && { echo "ERROR: --vm is required"; usage; }
[[ -z "$START_EPOCH" ]]      && { echo "ERROR: --start-epoch is required"; usage; }
[[ -z "$END_EPOCH" ]]        && { echo "ERROR: --end-epoch is required"; usage; }

export KUBECONFIG="$SOURCE_KUBECONFIG"

# Widen the query window by 60s on each side to catch metrics scraped
# slightly before/after the script-level timestamps.
QUERY_START=$((START_EPOCH - 60))
QUERY_END=$((END_EPOCH + 60))
STEP=15

# ──────────────────────────────────────────────
# Auth: discover Thanos route + SA token
# ──────────────────────────────────────────────

THANOS_HOST=$(kubectl get route thanos-querier -n openshift-monitoring \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [[ -z "$THANOS_HOST" ]]; then
  echo "ERROR: Could not discover Thanos route in openshift-monitoring" >&2
  exit 1
fi

THANOS_URL="https://${THANOS_HOST}"

TOKEN=$(kubectl create token prometheus-k8s -n openshift-monitoring \
  --duration=600s 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Could not create SA token for prometheus-k8s" >&2
  exit 1
fi

# ──────────────────────────────────────────────
# Prometheus query helpers
# ──────────────────────────────────────────────

prom_query() {
  local query="$1"
  curl -sk --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "query=${query}" \
    "${THANOS_URL}/api/v1/query" 2>/dev/null || echo '{"data":{"result":[]}}'
}

prom_range() {
  local query="$1"
  curl -sk --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${QUERY_START}" \
    --data-urlencode "end=${QUERY_END}" \
    --data-urlencode "step=${STEP}" \
    "${THANOS_URL}/api/v1/query_range" 2>/dev/null || echo '{"data":{"result":[]}}'
}

# Extract min/max/avg/samples from a range query result (first series).
# Returns a JSON object; null if no data.
summarize_range() {
  local raw="$1"
  echo "$raw" | jq '
    (.data.result[0].values // []) as $vals |
    if ($vals | length) == 0 then null
    else
      [$vals[] | .[1] | tonumber] |
      { min: min, max: max, avg: (add / length), samples: length }
    end
  ' 2>/dev/null || echo 'null'
}

# Extract the last non-zero value from a range query (first series).
last_value() {
  local raw="$1"
  echo "$raw" | jq '
    [.data.result[0].values[]? | .[1] | tonumber | select(. > 0)] | last // null
  ' 2>/dev/null || echo 'null'
}

# Extract a scalar from an instant query (first series).
instant_value() {
  local raw="$1"
  echo "$raw" | jq '
    .data.result[0].value[1] // null | if . then tonumber else null end
  ' 2>/dev/null || echo 'null'
}

echo "  Querying Thanos at ${THANOS_HOST}..." >&2

# ──────────────────────────────────────────────
# 1. Migration transfer metrics (range)
# ──────────────────────────────────────────────

RAW_DIRTY=$(prom_range "kubevirt_vmi_migration_dirty_memory_rate_bytes{namespace=\"${NAMESPACE}\"}")
RAW_DIRTY_VM=$(prom_range "kubevirt_vmi_dirty_rate_bytes_per_second{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")
RAW_XFER=$(prom_range "kubevirt_vmi_migration_memory_transfer_rate_bytes{namespace=\"${NAMESPACE}\"}")
RAW_TOTAL=$(prom_range "kubevirt_vmi_migration_data_total_bytes{namespace=\"${NAMESPACE}\"}")
RAW_PROC=$(prom_range "kubevirt_vmi_migration_data_processed_bytes{namespace=\"${NAMESPACE}\"}")
RAW_REM=$(prom_range "kubevirt_vmi_migration_data_remaining_bytes{namespace=\"${NAMESPACE}\"}")

DIRTY_SUMMARY=$(summarize_range "$RAW_DIRTY")
DIRTY_VM_SUMMARY=$(summarize_range "$RAW_DIRTY_VM")
XFER_SUMMARY=$(summarize_range "$RAW_XFER")
DATA_TOTAL=$(last_value "$RAW_TOTAL")
DATA_PROCESSED=$(last_value "$RAW_PROC")
DATA_REMAINING=$(last_value "$RAW_REM")

# ──────────────────────────────────────────────
# 2. Migration timestamps & counters (instant)
#    Note: start/end use label "name", succeeded/failed use label "vmi"
# ──────────────────────────────────────────────

_raw=$(prom_query "kubevirt_vmi_migration_start_time_seconds{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")
MIG_START_TS=$(instant_value "$_raw")
_raw=$(prom_query "kubevirt_vmi_migration_end_time_seconds{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")
MIG_END_TS=$(instant_value "$_raw")
_raw=$(prom_query "kubevirt_vmi_migration_succeeded{vmi=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")
MIG_SUCCEEDED=$(instant_value "$_raw")
_raw=$(prom_query "kubevirt_vmi_migration_failed{vmi=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")
MIG_FAILED=$(instant_value "$_raw")

# ──────────────────────────────────────────────
# 3. VM resource metrics during migration (range)
# ──────────────────────────────────────────────

_raw=$(prom_range "irate(kubevirt_vmi_cpu_usage_seconds_total{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}[60s])")
CPU_SUMMARY=$(summarize_range "$_raw")
_raw=$(prom_range "kubevirt_vmi_memory_used_bytes{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")
MEM_USED_SUMMARY=$(summarize_range "$_raw")
_raw=$(prom_range "kubevirt_vmi_memory_available_bytes{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")
MEM_AVAIL_SUMMARY=$(summarize_range "$_raw")
_raw=$(prom_range "irate(kubevirt_vmi_storage_iops_read_total{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}[60s])")
IOPS_READ_SUMMARY=$(summarize_range "$_raw")
_raw=$(prom_range "irate(kubevirt_vmi_storage_iops_write_total{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}[60s])")
IOPS_WRITE_SUMMARY=$(summarize_range "$_raw")
_raw=$(prom_range "irate(kubevirt_vmi_storage_read_times_seconds_total{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}[60s])")
DISK_LAT_READ=$(summarize_range "$_raw")
_raw=$(prom_range "irate(kubevirt_vmi_storage_write_times_seconds_total{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}[60s])")
DISK_LAT_WRITE=$(summarize_range "$_raw")
_raw=$(prom_range "irate(kubevirt_vmi_network_receive_bytes_total{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}[60s])")
NET_RX_SUMMARY=$(summarize_range "$_raw")
_raw=$(prom_range "irate(kubevirt_vmi_network_transmit_bytes_total{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}[60s])")
NET_TX_SUMMARY=$(summarize_range "$_raw")
GUEST_LOAD_SUMMARY=$(summarize_range "$(prom_range "kubevirt_vmi_guest_load_1m{name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\"}")")

# ──────────────────────────────────────────────
# 4. MTV metrics (instant)
# ──────────────────────────────────────────────

MTV_DURATION_RAW=$(prom_query "mtv_migration_duration_seconds{namespace=\"openshift-mtv\"}")
MTV_DURATION=$(echo "$MTV_DURATION_RAW" | jq '[.data.result[]? | .value[1] | tonumber] | max // null' 2>/dev/null || echo 'null')

MTV_STATUS_RAW=$(prom_query "mtv_migrations_status_total{namespace=\"openshift-mtv\"}")
MTV_STATUS=$(echo "$MTV_STATUS_RAW" | jq '
  [.data.result[]? | {(.metric.status): (.value[1] | tonumber)}] | add // {}
' 2>/dev/null || echo '{}')

# ──────────────────────────────────────────────
# 5. VMIM CR extraction
# ──────────────────────────────────────────────

echo "  Extracting VMIM CR data..." >&2

VMIM_JSON=$(kubectl get vmim -A -o json --request-timeout=15s 2>/dev/null \
  | jq --arg vm "$VM_NAME" '
    [.items[] | select(.spec.vmiName == $vm)] |
    sort_by(.status.migrationState.startTimestamp // "") |
    last // null
  ' 2>/dev/null || echo 'null')

VMIM_EXTRACTED=$(echo "$VMIM_JSON" | jq '
  if . == null then null
  else
    .status as $s |
    ($s.migrationState // {}) as $ms |
    ($s.phaseTransitionTimestamps // []) as $pt |

    # Build phase map: {phase: timestamp}
    ([$pt[] | {(.phase): .phaseTransitionTimestamp}] | add // {}) as $pm |

    # Derive durations (ISO 8601 -> epoch via split+parse is fragile in jq,
    # so store raw timestamps; the caller can compute durations).
    {
      name: .metadata.name,
      mode: ($ms.mode // null),
      completed: ($ms.completed // null),
      failed: ($ms.failed // null),
      source_node: ($ms.sourceNode // null),
      target_node: ($ms.targetNode // null),
      start_timestamp: ($ms.startTimestamp // null),
      end_timestamp: ($ms.endTimestamp // null),
      target_domain_ready_timestamp: ($ms.targetNodeDomainReadyTimestamp // null),
      migration_configuration: ($ms.migrationConfiguration // null),
      phase_transitions: $pm,
      phase_transition_list: $pt
    }
  end
' 2>/dev/null || echo 'null')

# Compute derived durations using date command (more reliable than jq for ISO 8601)
derive_duration() {
  local start_ts="$1" end_ts="$2"
  if [[ -n "$start_ts" && "$start_ts" != "null" && -n "$end_ts" && "$end_ts" != "null" ]]; then
    local s e
    s=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_ts" "+%s" 2>/dev/null \
      || date -d "$start_ts" "+%s" 2>/dev/null || echo "")
    e=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_ts" "+%s" 2>/dev/null \
      || date -d "$end_ts" "+%s" 2>/dev/null || echo "")
    if [[ -n "$s" && -n "$e" ]]; then
      echo $((e - s))
      return
    fi
  fi
  echo "null"
}

VMIM_START=$(echo "$VMIM_EXTRACTED" | jq -r '.start_timestamp // empty' 2>/dev/null || true)
VMIM_END=$(echo "$VMIM_EXTRACTED" | jq -r '.end_timestamp // empty' 2>/dev/null || true)
VMIM_RUNNING=$(echo "$VMIM_EXTRACTED" | jq -r '.phase_transitions.Running // empty' 2>/dev/null || true)
VMIM_SUCCEEDED=$(echo "$VMIM_EXTRACTED" | jq -r '.phase_transitions.Succeeded // empty' 2>/dev/null || true)
VMIM_SCHEDULING=$(echo "$VMIM_EXTRACTED" | jq -r '.phase_transitions.Scheduling // empty' 2>/dev/null || true)
VMIM_TARGET_READY=$(echo "$VMIM_EXTRACTED" | jq -r '.target_domain_ready_timestamp // empty' 2>/dev/null || true)

PAGE_STREAMING_SEC=$(derive_duration "$VMIM_RUNNING" "$VMIM_SUCCEEDED")
SCHEDULING_TO_RUNNING_SEC=$(derive_duration "$VMIM_SCHEDULING" "$VMIM_RUNNING")
TOTAL_VMIM_SEC=$(derive_duration "$VMIM_START" "$VMIM_END")
# Stop-and-copy approximation: from Running start to endTimestamp
STOP_COPY_SEC=$(derive_duration "$VMIM_RUNNING" "$VMIM_END")

DERIVED_DURATIONS=$(jq -n \
  --argjson pss "$PAGE_STREAMING_SEC" \
  --argjson str "$SCHEDULING_TO_RUNNING_SEC" \
  --argjson tvs "$TOTAL_VMIM_SEC" \
  --argjson scs "$STOP_COPY_SEC" \
  '{
    page_streaming_sec: $pss,
    scheduling_to_running_sec: $str,
    total_vmim_sec: $tvs,
    stop_and_copy_sec: $scs
  }')

# Merge derived durations into VMIM object
VMIM_FINAL=$(echo "$VMIM_EXTRACTED" | jq --argjson dd "$DERIVED_DURATIONS" '. + {derived_durations: $dd}' 2>/dev/null || echo 'null')

# ──────────────────────────────────────────────
# Assemble final JSON
# ──────────────────────────────────────────────

RESULT=$(jq -n \
  --argjson qstart "$QUERY_START" \
  --argjson qend "$QUERY_END" \
  --argjson dirty "$DIRTY_SUMMARY" \
  --argjson dirty_vm "$DIRTY_VM_SUMMARY" \
  --argjson xfer "$XFER_SUMMARY" \
  --argjson dtotal "$DATA_TOTAL" \
  --argjson dproc "$DATA_PROCESSED" \
  --argjson drem "$DATA_REMAINING" \
  --argjson mstart "$MIG_START_TS" \
  --argjson mend "$MIG_END_TS" \
  --argjson msucc "${MIG_SUCCEEDED:-null}" \
  --argjson mfail "${MIG_FAILED:-null}" \
  --argjson cpu "$CPU_SUMMARY" \
  --argjson mem_used "$MEM_USED_SUMMARY" \
  --argjson mem_avail "$MEM_AVAIL_SUMMARY" \
  --argjson iops_r "$IOPS_READ_SUMMARY" \
  --argjson iops_w "$IOPS_WRITE_SUMMARY" \
  --argjson dlat_r "$DISK_LAT_READ" \
  --argjson dlat_w "$DISK_LAT_WRITE" \
  --argjson net_rx "$NET_RX_SUMMARY" \
  --argjson net_tx "$NET_TX_SUMMARY" \
  --argjson guest "$GUEST_LOAD_SUMMARY" \
  --argjson mtv_dur "$MTV_DURATION" \
  --argjson mtv_st "$MTV_STATUS" \
  --argjson vmim "$VMIM_FINAL" \
  '{
    query_window: { start_epoch: $qstart, end_epoch: $qend },
    migration_transfer: {
      dirty_memory_rate_bytes: $dirty,
      dirty_rate_vm_bytes_per_sec: $dirty_vm,
      memory_transfer_rate_bytes: $xfer,
      data_total_bytes: $dtotal,
      data_processed_bytes: $dproc,
      data_remaining_bytes_final: $drem
    },
    migration_timestamps: {
      start_epoch: $mstart,
      end_epoch: $mend,
      succeeded_count: $msucc,
      failed_count: $mfail
    },
    vm_resources: {
      cpu_usage_rate: $cpu,
      memory_used_bytes: $mem_used,
      memory_available_bytes: $mem_avail,
      disk_iops_read: $iops_r,
      disk_iops_write: $iops_w,
      disk_latency_read_sec: $dlat_r,
      disk_latency_write_sec: $dlat_w,
      network_rx_bytes_per_sec: $net_rx,
      network_tx_bytes_per_sec: $net_tx,
      guest_load_1m: $guest
    },
    mtv: {
      duration_sec: $mtv_dur,
      status_totals: $mtv_st
    },
    vmim: $vmim
  }')

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$RESULT" > "$OUTPUT_FILE"
  echo "  Prometheus metrics written to: ${OUTPUT_FILE}" >&2
else
  echo "$RESULT"
fi
