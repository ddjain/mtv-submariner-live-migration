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
STABILIZE_WAIT=30
LARGE_DATA_SIZE_MB=500
LARGE_DATA_SIZE_MB_EPHEMERAL=100
PAUSE_BEFORE_MIGRATION="false"
SKIP_PROMETHEUS_METRICS="false"
CHAOS_SCENARIO=""

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
  --ssh-ready-timeout SEC            Max seconds to wait for guest SSH before setup (default: 600)
  --stabilize-wait SEC               Seconds to wait after workload setup before pre-check (default: 30)
  --large-data-size-mb MB            Size of persistent test data file in MB (default: 500)
  --large-data-size-mb-ephemeral MB  Size of ephemeral test data file in MB (default: 100)
  --pause-before-migration           Pause before migration step and wait for user to press Enter
  --skip-prometheus-metrics          Skip Prometheus/VMIM metrics collection after migration
  --chaos-scenario NAME          Label for the chaos test being run (e.g. kill-source-virt-launcher)

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
    --local-ssh-opts)                 LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout)              SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --stabilize-wait)                 STABILIZE_WAIT="$2"; shift 2 ;;
    --large-data-size-mb)             LARGE_DATA_SIZE_MB="$2"; shift 2 ;;
    --large-data-size-mb-ephemeral)   LARGE_DATA_SIZE_MB_EPHEMERAL="$2"; shift 2 ;;
    --pause-before-migration)         PAUSE_BEFORE_MIGRATION="true"; shift ;;
    --skip-prometheus-metrics)       SKIP_PROMETHEUS_METRICS="true"; shift ;;
    --chaos-scenario)               CHAOS_SCENARIO="$2"; shift 2 ;;
    -h|--help)                        usage ;;
    *)                                echo "Unknown option: $1"; usage ;;
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

step_banner() {
  echo ""
  echo "================================================================"
  echo "  $1"
  echo "================================================================"
}

capture_pod_restarts() {
  local kc="$1"; shift
  local result="[]"
  for ns in "$@"; do
    local pods_json
    pods_json="$(KUBECONFIG="$kc" kubectl get pods -n "$ns" -o json 2>/dev/null \
      || echo '{"items":[]}')"
    local ns_restarts
    ns_restarts="$(echo "$pods_json" | jq --arg ns "$ns" \
      '[.items[] | {namespace: $ns, pod: .metadata.name, restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)}]')"
    result="$(echo "$result" "$ns_restarts" | jq -s 'add')"
  done
  echo "$result"
}

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

step_banner "[1/6] CREATE VM"
"${SCRIPT_DIR}/create-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "${SSH_KEY}.pub" \
  --template "${TEMPLATE_DIR}/vm.yaml.template" \
  --output-dir "$GENERATED_DIR"

echo ""
echo "  ---- VM Details (source cluster) ----"
echo "  Name:       ${VM_NAME}"
echo "  Namespace:  ${NAMESPACE}"
VM_NODE="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "n/a")"
VM_IP="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "n/a")"
VM_PHASE="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "n/a")"
VM_READY="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "n/a")"
echo "  Node:       ${VM_NODE}"
echo "  Pod IP:     ${VM_IP}"
echo "  VMI Phase:  ${VM_PHASE}"
echo "  VM Ready:   ${VM_READY}"
echo ""
echo "  # Copy-paste for krknctl / chaos (same variable names as your shell):"
echo "  export VM_NAME=\"${VM_NAME}\""
echo "  export KUBECONFIG_PATH=\"${SOURCE_KUBECONFIG}\""
echo "  export NAMESPACE=\"${NAMESPACE}\""
if [[ -n "${VM_NODE}" ]] && [[ "${VM_NODE}" != "n/a" ]]; then
  echo "  export NODE_LABEL_SELECTOR=\"kubernetes.io/hostname=${VM_NODE}\""
else
  echo "  export NODE_LABEL_SELECTOR=\"\"  # set node: kubectl get vmi ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.nodeName}'"
fi
echo "  --------------------------------------"

step_banner "[2/6] SETUP WORKLOADS"
"${SCRIPT_DIR}/setup-vm-workloads.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --ssh-ready-timeout "$SSH_READY_TIMEOUT" \
  --large-data-size-mb "$LARGE_DATA_SIZE_MB" \
  --large-data-size-mb-ephemeral "$LARGE_DATA_SIZE_MB_EPHEMERAL" \
  --local-ssh-opts "$LOCAL_SSH_OPTS"

echo ""
echo "  Waiting ${STABILIZE_WAIT}s for workloads to stabilize..."
sleep "${STABILIZE_WAIT}"

step_banner "[3/6] PRE-MIGRATION CHECK"
"${SCRIPT_DIR}/pre-migration-check.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$REPORT_DIR" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout 300

PRE_FILE="$(ls -t "${REPORT_DIR}/pre-migration-${VM_NAME}-"*.json 2>/dev/null | head -1 || true)"
[[ -n "$PRE_FILE" ]] || { echo "ERROR: Could not find pre-migration JSON for ${VM_NAME}"; exit 1; }
echo "Using pre-migration baseline: ${PRE_FILE}"

# Pause before migration if requested
if [[ "$PAUSE_BEFORE_MIGRATION" == "true" ]]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════╗"
  echo "║                         PAUSED BEFORE MIGRATION                            ║"
  echo "╚════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  VM Details:"
  echo "    Name:       ${VM_NAME}"
  echo "    Namespace:  ${NAMESPACE}"
  echo "    Node:       $(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo 'n/a')"
  echo "    Pod IP:     $(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo 'n/a')"
  echo ""
  echo "  Pre-migration baseline: ${PRE_FILE}"
  echo ""
  echo "  You can now:"
  echo "    • Inspect VM state:           make ssh-source VM_NAME=${VM_NAME}"
  echo "    • Run additional pre-checks:  make pre-check VM_NAME=${VM_NAME}"
  echo "    • Simulate pod restart:       kubectl delete pod -n ${NAMESPACE} -l kubevirt.io/vm=${VM_NAME}"
  echo "    • Run chaos experiments"
  echo ""
  read -p "  Press Enter to continue with migration, or Ctrl+C to abort... " _
  echo ""
fi

echo "  Capturing pod restart counts (pre-migration)..."
PRE_RESTARTS_SOURCE=$(capture_pod_restarts "$SOURCE_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")
PRE_RESTARTS_TARGET=$(capture_pod_restarts "$TARGET_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")

step_banner "[4/6] MIGRATE VM"
"${SCRIPT_DIR}/migrate-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --template-dir "$TEMPLATE_DIR" \
  --output-dir "$GENERATED_DIR"

step_banner "[5/6] WAIT FOR MIGRATION (up to 60 checks, 10s apart)"
MAX_ATTEMPTS=60
MIGRATION_START_TIME=$(date +%s)
LAST_STEP=""

echo "Monitoring migration progress..."
echo ""

MIGRATION_FAILED=false

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  # Get comprehensive migration status
  MIG_STATUS="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" \
    -n openshift-mtv -o json 2>/dev/null || echo '{}')"

  # Extract key status fields
  succ="$(echo "$MIG_STATUS" | jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' 2>/dev/null || echo "")"
  vm_phase="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].phase // "Pending"' 2>/dev/null || echo "Pending")"

  # Get pipeline steps
  pipeline_json="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? // empty' 2>/dev/null || echo "")"

  # Find current step (first non-Completed step)
  current_step="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | select(.phase != "Completed") | .name' 2>/dev/null | head -1 || echo "")"
  current_step_desc="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | select(.phase != "Completed") | .description' 2>/dev/null | head -1 || echo "")"
  current_step_phase="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | select(.phase != "Completed") | .phase' 2>/dev/null | head -1 || echo "")"

  # Count completed vs total steps
  total_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]?] | length' 2>/dev/null || echo "0")"
  completed_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]? | select(.phase == "Completed")] | length' 2>/dev/null || echo "0")"

  # Calculate elapsed time
  ELAPSED=$(($(date +%s) - MIGRATION_START_TIME))
  ELAPSED_MIN=$((ELAPSED / 60))
  ELAPSED_SEC=$((ELAPSED % 60))

  # Check for completion
  if [[ "$vm_phase" == "Completed" ]] || [[ "$succ" == "True" ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════════╗"
    echo "║                      MIGRATION COMPLETED SUCCESSFULLY                      ║"
    echo "╚════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Total time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
    echo "  Final phase: ${vm_phase}"
    echo ""
    break
  fi

  # Check for failure
  if [[ "$vm_phase" == "Failed" ]]; then
    echo ""
    echo "ERROR: Migration failed!"
    echo ""
    echo "Pipeline status:"
    echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | "  [\(.phase)] \(.name): \(.description)"' 2>/dev/null || echo "  Unable to retrieve pipeline status"
    echo ""
    KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" -n openshift-mtv -o yaml || true
    MIGRATION_FAILED=true
    break
  fi

  # Timeout check
  if [[ "$i" -eq "$MAX_ATTEMPTS" ]]; then
    echo ""
    echo "ERROR: Migration did not complete after ${MAX_ATTEMPTS} checks (~$((MAX_ATTEMPTS * 10))s)."
    echo ""
    echo "Last known status:"
    echo "  VM Phase: ${vm_phase}"
    echo "  Current step: ${current_step:-unknown}"
    echo "  Progress: ${completed_steps}/${total_steps} steps"
    echo ""
    KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" -n openshift-mtv -o yaml || true
    MIGRATION_FAILED=true
    break
  fi

  # Display progress update (show new step or every 5th check)
  if [[ "$current_step" != "$LAST_STEP" ]] || [[ $((i % 5)) -eq 0 ]]; then
    printf "  [%2d/%2d] %dm%02ds | Phase: %-12s | Steps: %d/%d" \
      "$i" "$MAX_ATTEMPTS" "$ELAPSED_MIN" "$ELAPSED_SEC" "$vm_phase" "$completed_steps" "$total_steps"

    if [[ -n "$current_step" ]]; then
      printf " | %-18s: %s\n" "$current_step" "$current_step_desc"
    else
      printf " | Initializing...\n"
    fi

    LAST_STEP="$current_step"
  fi

  sleep 10
done

# --- Migration Metrics Collection ---

# Determine migration outcome from final loop state
MIGRATION_DURATION_SEC="${ELAPSED:-0}"
if [[ "$vm_phase" == "Completed" ]] || [[ "$succ" == "True" ]]; then
  MIGRATION_OUTCOME="succeeded"
elif [[ "$vm_phase" == "Failed" ]]; then
  MIGRATION_OUTCOME="failed"
else
  MIGRATION_OUTCOME="timeout"
fi

# Extract pipeline step timings from the last Migration CR snapshot
PIPELINE_TIMINGS="$(echo "$MIG_STATUS" | jq \
  '[.status.vms[0].pipeline[]? | {name, description, phase, started, completed}]' \
  2>/dev/null || echo '[]')"

echo "  Capturing pod restart counts (post-migration)..."
POST_RESTARTS_SOURCE=$(capture_pod_restarts "$SOURCE_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")
POST_RESTARTS_TARGET=$(capture_pod_restarts "$TARGET_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")

POD_RESTART_DIFF="$(jq -n \
  --argjson pre_s "$PRE_RESTARTS_SOURCE" \
  --argjson post_s "$POST_RESTARTS_SOURCE" \
  --argjson pre_t "$PRE_RESTARTS_TARGET" \
  --argjson post_t "$POST_RESTARTS_TARGET" '
  [($post_s[]? as $p |
    ($pre_s | map(select(.pod == $p.pod)) | .[0].restarts // 0) as $pre_r |
    {cluster: "source", namespace: $p.namespace, pod: $p.pod,
     pre: $pre_r, post: $p.restarts, diff: ($p.restarts - $pre_r)}
    | select(.diff > 0)
  )] +
  [($post_t[]? as $p |
    ($pre_t | map(select(.pod == $p.pod)) | .[0].restarts // 0) as $pre_r |
    {cluster: "target", namespace: $p.namespace, pod: $p.pod,
     pre: $pre_r, post: $p.restarts, diff: ($p.restarts - $pre_r)}
    | select(.diff > 0)
  )]
' 2>/dev/null || echo '[]')"

METRICS_TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
MIGRATION_METRICS_FILE="${REPORT_DIR}/migration-metrics-${VM_NAME}-${METRICS_TIMESTAMP}.json"

jq -n \
  --arg vm "$VM_NAME" \
  --arg ns "$NAMESPACE" \
  --arg chaos "$CHAOS_SCENARIO" \
  --arg outcome "$MIGRATION_OUTCOME" \
  --argjson duration "$MIGRATION_DURATION_SEC" \
  --argjson start_epoch "$MIGRATION_START_TIME" \
  --argjson pipeline "$PIPELINE_TIMINGS" \
  --argjson restarts "$POD_RESTART_DIFF" \
  '{
    vm_name: $vm,
    namespace: $ns,
    chaos_scenario: $chaos,
    migration: {
      outcome: $outcome,
      duration_sec: $duration,
      start_epoch: $start_epoch,
      pipeline_steps: $pipeline
    },
    pod_restarts: {
      pods_with_new_restarts: $restarts
    }
  }' > "$MIGRATION_METRICS_FILE"

echo "  Migration metrics saved to: ${MIGRATION_METRICS_FILE}"

# --- Prometheus + VMIM Metrics (enabled by default) ---
if [[ "$SKIP_PROMETHEUS_METRICS" != "true" ]]; then
  MIGRATION_END_TIME=$(date +%s)
  PROM_METRICS_FILE="${REPORT_DIR}/prometheus-metrics-${VM_NAME}-${METRICS_TIMESTAMP}.json"
  echo "  Capturing Prometheus metrics and VMIM data..."
  if "${SCRIPT_DIR}/capture-prometheus-metrics.sh" \
      --source-kubeconfig "$SOURCE_KUBECONFIG" \
      --vm "$VM_NAME" \
      --namespace "$NAMESPACE" \
      --start-epoch "$MIGRATION_START_TIME" \
      --end-epoch "$MIGRATION_END_TIME" \
      --output-file "$PROM_METRICS_FILE"; then
    jq -s '.[0] * {prometheus: .[1]}' \
      "$MIGRATION_METRICS_FILE" "$PROM_METRICS_FILE" > "${MIGRATION_METRICS_FILE}.tmp" \
      && mv "${MIGRATION_METRICS_FILE}.tmp" "$MIGRATION_METRICS_FILE"
    echo "  Prometheus metrics merged into: ${MIGRATION_METRICS_FILE}"
  else
    echo "  WARNING: Prometheus metrics capture failed (non-fatal), continuing..."
  fi
else
  echo "  Prometheus metrics collection skipped (--skip-prometheus-metrics)."
fi

if [[ "$MIGRATION_FAILED" == "true" ]]; then
  echo ""
  echo "  Migration failed but metrics were captured."
  echo "  Exiting with error."
  exit 1
fi

step_banner "[6/6] POST-MIGRATION CHECK (target cluster)"
"${SCRIPT_DIR}/post-migration-check.sh" \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$REPORT_DIR" \
  --pre-migration-file "$PRE_FILE" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout "$SSH_READY_TIMEOUT"

echo ""
echo "================================================================"
echo "  E2E completed for VM: ${VM_NAME}"
echo "================================================================"
echo ""
