#!/usr/bin/env bash
#
# End-to-end: create VM -> setup workloads -> pre-check -> migrate -> wait for completion -> post-check
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Shared libraries ──────────────────────────────────────────
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/k8s.sh"

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
POST_SSH_READY_TIMEOUT=225
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
  --verbose                      Set LOG_LEVEL=2 (operational detail)
  --debug                        Set LOG_LEVEL=3 (raw trace)

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
    --verbose)                       export LOG_LEVEL=2; shift ;;
    --debug)                         export LOG_LEVEL=3; shift ;;
    -h|--help)                        usage ;;
    *)                                echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SOURCE_KUBECONFIG" ]] && { echo "ERROR: --source-kubeconfig is required"; usage; }
[[ -z "$TARGET_KUBECONFIG" ]] && { echo "ERROR: --target-kubeconfig is required"; usage; }

export LOG_LEVEL

TEMPLATE_DIR="${TEMPLATE_DIR:-${SCRIPT_DIR}/../../templates}"
GENERATED_DIR="${GENERATED_DIR:-${SCRIPT_DIR}/generated}"
REPORT_DIR="${REPORT_DIR:-${SCRIPT_DIR}/reports}"

if [[ -z "${LOCAL_SSH_OPTS}" ]]; then
  LOCAL_SSH_OPTS="$LOCAL_SSH_OPTS_DEFAULT"
fi

mkdir -p "$GENERATED_DIR" "$REPORT_DIR"

RUN_TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
PIPELINE_START_TIME=$(date +%s)

# ── Enable failure auto-expansion ─────────────────────────────
log.enable_failure_context

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

if [[ -n "$CHAOS_SCENARIO" ]]; then
  RUN_REPORT_DIR="${REPORT_DIR}/${CHAOS_SCENARIO}-${VM_NAME}-${RUN_TIMESTAMP}"
else
  RUN_REPORT_DIR="${REPORT_DIR}/${VM_NAME}-${RUN_TIMESTAMP}"
fi
mkdir -p "$RUN_REPORT_DIR"

# ── Pipeline header ───────────────────────────────────────────
log.banner "E2E Migration Pipeline"
log.info "  VM_NAME:    ${VM_NAME}"
log.info "  Namespace:  ${NAMESPACE}"
log.info "  Report Dir: ${RUN_REPORT_DIR}"
[[ -n "$CHAOS_SCENARIO" ]] && log.info "  Chaos:      ${CHAOS_SCENARIO}"
log.info ""

# ══════════════════════════════════════════════════════════════
# [1/6] CREATE VM
# ══════════════════════════════════════════════════════════════

step.begin "[1/6] CREATE VM"
"${SCRIPT_DIR}/create-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "${SSH_KEY}.pub" \
  --template "${TEMPLATE_DIR}/vm.yaml.template" \
  --output-dir "$GENERATED_DIR"

VM_NODE="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "n/a")"
VM_IP="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "n/a")"
VM_PHASE="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "n/a")"
VM_READY="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "n/a")"

step.end "PASS"

log.verbose "VM Details:"
log.verbose "  Name: ${VM_NAME}  Node: ${VM_NODE}  IP: ${VM_IP}  Phase: ${VM_PHASE}  Ready: ${VM_READY}"
log.verbose ""
log.verbose "Copy-paste for krknctl / chaos:"
log.verbose "  export VM_NAME=\"${VM_NAME}\""
log.verbose "  export KUBECONFIG_PATH=\"${SOURCE_KUBECONFIG}\""
log.verbose "  export NAMESPACE=\"${NAMESPACE}\""
if [[ -n "${VM_NODE}" ]] && [[ "${VM_NODE}" != "n/a" ]]; then
  log.verbose "  export NODE_LABEL_SELECTOR=\"kubernetes.io/hostname=${VM_NODE}\""
else
  log.verbose "  export NODE_LABEL_SELECTOR=\"\"  # set node manually"
fi

# ══════════════════════════════════════════════════════════════
# [2/6] SETUP WORKLOADS
# ══════════════════════════════════════════════════════════════

step.begin "[2/6] SETUP WORKLOADS"
"${SCRIPT_DIR}/setup-vm-workloads.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --template-dir "$TEMPLATE_DIR" \
  --ssh-ready-timeout "$SSH_READY_TIMEOUT" \
  --large-data-size-mb "$LARGE_DATA_SIZE_MB" \
  --large-data-size-mb-ephemeral "$LARGE_DATA_SIZE_MB_EPHEMERAL" \
  --local-ssh-opts "$LOCAL_SSH_OPTS"

task.begin "Stabilizing workloads"
log.verbose "Waiting ${STABILIZE_WAIT}s for workloads to stabilize..."
sleep "${STABILIZE_WAIT}"
task.pass "Stabilized" "(${STABILIZE_WAIT}s)"

step.end "PASS"

# ══════════════════════════════════════════════════════════════
# [3/6] PRE-MIGRATION CHECK
# ══════════════════════════════════════════════════════════════

step.begin "[3/6] PRE-MIGRATION CHECK"
"${SCRIPT_DIR}/pre-migration-check.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$RUN_REPORT_DIR" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout 300 \
  --chaos-scenario "$CHAOS_SCENARIO"

PRE_FILE="$(ls -t "${RUN_REPORT_DIR}/pre-migration-${VM_NAME}-"*.json 2>/dev/null | head -1 || true)"
[[ -n "$PRE_FILE" ]] || { log.error "Could not find pre-migration JSON for ${VM_NAME}"; exit 1; }
log.verbose "Using pre-migration baseline: ${PRE_FILE}"

step.end "PASS"

# ── Pause before migration ────────────────────────────────────
if [[ "$PAUSE_BEFORE_MIGRATION" == "true" ]]; then
  log.box \
    "PAUSED BEFORE MIGRATION" \
    "" \
    "VM:         ${VM_NAME}" \
    "Namespace:  ${NAMESPACE}" \
    "Node:       $(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo 'n/a')" \
    "Pod IP:     $(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo 'n/a')" \
    "" \
    "Baseline: ${PRE_FILE}" \
    "" \
    "Steps completed:" \
    "  ✓ [1/6] CREATE VM" \
    "  ✓ [2/6] SETUP WORKLOADS" \
    "  ✓ [3/6] PRE-MIGRATION CHECK" \
    "" \
    "Steps remaining:" \
    "  ○ [4/6] MIGRATE VM" \
    "  ○ [5/6] WAIT FOR MIGRATION" \
    "  ○ [6/6] POST-MIGRATION CHECK" \
    "" \
    "Quick actions:" \
    "  • SSH:   make ssh-source VM_NAME=${VM_NAME}" \
    "  • Chaos: bash clusters/scripts/chaos-trigger.sh"
  echo ""
  read -p "  → Press Enter to continue with migration, or Ctrl+C to abort... " _
  echo ""
fi

task.begin "Capturing pod restarts (pre-migration)"
PRE_RESTARTS_SOURCE=$(capture_pod_restarts "$SOURCE_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")
PRE_RESTARTS_TARGET=$(capture_pod_restarts "$TARGET_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")
task.pass "Pod restarts captured"

# ══════════════════════════════════════════════════════════════
# [4/6] MIGRATE VM
# ══════════════════════════════════════════════════════════════

step.begin "[4/6] MIGRATE VM"
"${SCRIPT_DIR}/migrate-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --template-dir "$TEMPLATE_DIR" \
  --output-dir "$GENERATED_DIR"

task.begin "Copying manifests to report folder"
for f in "${GENERATED_DIR}/${VM_NAME}-vm.yaml" \
         "${GENERATED_DIR}/${VM_NAME}-migration-plan.yaml" \
         "${GENERATED_DIR}/${VM_NAME}-migration.yaml"; do
  [[ -f "$f" ]] && cp "$f" "$RUN_REPORT_DIR/"
done
task.pass "Manifests copied"

step.end "PASS"

# ══════════════════════════════════════════════════════════════
# [5/6] WAIT FOR MIGRATION
# ══════════════════════════════════════════════════════════════

step.begin "[5/6] WAIT FOR MIGRATION"
MAX_ATTEMPTS=60
MIGRATION_START_TIME=$(date +%s)
LAST_STEP=""

log.verbose "Monitoring migration progress (up to ${MAX_ATTEMPTS} checks, 10s apart)..."

MIGRATION_FAILED=false

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  MIG_STATUS="$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" \
    -n openshift-mtv -o json 2>/dev/null || echo '{}')"

  succ="$(echo "$MIG_STATUS" | jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' 2>/dev/null || echo "")"
  vm_phase="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].phase // "Pending"' 2>/dev/null || echo "Pending")"

  current_step="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | select(.phase != "Completed") | .name' 2>/dev/null | head -1 || echo "")"
  current_step_desc="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | select(.phase != "Completed") | .description' 2>/dev/null | head -1 || echo "")"

  total_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]?] | length' 2>/dev/null || echo "0")"
  completed_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]? | select(.phase == "Completed")] | length' 2>/dev/null || echo "0")"

  ELAPSED=$(($(date +%s) - MIGRATION_START_TIME))
  ELAPSED_MIN=$((ELAPSED / 60))
  ELAPSED_SEC=$((ELAPSED % 60))

  # ── Completed successfully ──
  if [[ "$vm_phase" == "Completed" ]] || [[ "$succ" == "True" ]]; then
    [[ -n "$LAST_STEP" ]] && task.pass "$LAST_STEP"
    task.pass "Migration completed" "(${ELAPSED_MIN}m${ELAPSED_SEC}s)"
    step.end "PASS"
    break
  fi

  # ── Failed ──
  if [[ "$vm_phase" == "Failed" ]]; then
    [[ -n "$LAST_STEP" ]] && task.fail "$LAST_STEP" "phase=$vm_phase"
    log.error "Migration failed!"
    log.info ""
    log.info "   Pipeline status:"
    echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | "     [\(.phase)] \(.name): \(.description)"' 2>/dev/null || log.info "     Unable to retrieve pipeline status"
    log.info ""
    log.debug "$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" -n openshift-mtv -o yaml 2>/dev/null || true)"
    step.end "FAIL"
    MIGRATION_FAILED=true
    break
  fi

  # ── Timeout ──
  if [[ "$i" -eq "$MAX_ATTEMPTS" ]]; then
    log.error "Migration did not complete after ${MAX_ATTEMPTS} checks (~$((MAX_ATTEMPTS * 10))s)."
    log.info "   Last status: Phase=${vm_phase} Step=${current_step:-unknown} Progress=${completed_steps}/${total_steps}"
    log.debug "$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration "${VM_NAME}-migration" -n openshift-mtv -o yaml 2>/dev/null || true)"
    step.end "FAIL"
    MIGRATION_FAILED=true
    break
  fi

  # ── Progress ──
  if [[ "$current_step" != "$LAST_STEP" ]]; then
    [[ -n "$LAST_STEP" ]] && task.pass "$LAST_STEP"
    task.begin "${current_step:-Initializing}"
    log.verbose "${current_step_desc:-Waiting for pipeline to start}"
    LAST_STEP="$current_step"
  fi

  progress.update "${current_step:-Initializing}" "${completed_steps}/${total_steps} steps (${ELAPSED_MIN}m${ELAPSED_SEC}s)"

  sleep 10
done

# ── Migration metrics collection ──────────────────────────────

MIGRATION_DURATION_SEC="${ELAPSED:-0}"
if [[ "$vm_phase" == "Completed" ]] || [[ "$succ" == "True" ]]; then
  MIGRATION_OUTCOME="succeeded"
elif [[ "$vm_phase" == "Failed" ]]; then
  MIGRATION_OUTCOME="failed"
else
  MIGRATION_OUTCOME="timeout"
fi

PIPELINE_TIMINGS="$(echo "$MIG_STATUS" | jq \
  '[.status.vms[0].pipeline[]? | {name, description, phase, started, completed}]' \
  2>/dev/null || echo '[]')"

task.begin "Capturing pod restarts (post-migration)"
POST_RESTARTS_SOURCE=$(capture_pod_restarts "$SOURCE_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")
POST_RESTARTS_TARGET=$(capture_pod_restarts "$TARGET_KUBECONFIG" \
  openshift-cnv openshift-mtv submariner-operator "$NAMESPACE")
task.pass "Pod restarts captured"

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

RESTART_COUNT="$(echo "$POD_RESTART_DIFF" | jq 'length' 2>/dev/null || echo 0)"
if [[ "$RESTART_COUNT" -gt 0 ]]; then
  log.warn "Pod restarts detected during migration: ${RESTART_COUNT} pod(s)"
  log.verbose "$(echo "$POD_RESTART_DIFF" | jq -r '.[] | "  \(.cluster)/\(.namespace)/\(.pod) +\(.diff)"' 2>/dev/null || true)"
fi

METRICS_TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
MIGRATION_METRICS_FILE="${RUN_REPORT_DIR}/migration-metrics-${VM_NAME}-${METRICS_TIMESTAMP}.json"

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

log.verbose "Migration metrics saved to: ${MIGRATION_METRICS_FILE}"

# ── Prometheus + VMIM Metrics ─────────────────────────────────
if [[ "$SKIP_PROMETHEUS_METRICS" != "true" ]]; then
  MIGRATION_END_TIME=$(date +%s)
  PROM_METRICS_FILE="${RUN_REPORT_DIR}/prometheus-metrics-${VM_NAME}-${METRICS_TIMESTAMP}.json"
  task.begin "Capturing Prometheus metrics"
  if "${SCRIPT_DIR}/capture-prometheus-metrics.sh" \
      --source-kubeconfig "$SOURCE_KUBECONFIG" \
      --vm "$VM_NAME" \
      --namespace "$NAMESPACE" \
      --start-epoch "$MIGRATION_START_TIME" \
      --end-epoch "$MIGRATION_END_TIME" \
      --output-file "$PROM_METRICS_FILE" \
      --chaos-scenario "$CHAOS_SCENARIO"; then
    jq -s '.[0] * {prometheus: .[1]}' \
      "$MIGRATION_METRICS_FILE" "$PROM_METRICS_FILE" > "${MIGRATION_METRICS_FILE}.tmp" \
      && mv "${MIGRATION_METRICS_FILE}.tmp" "$MIGRATION_METRICS_FILE"
    task.pass "Prometheus metrics merged"
  else
    task.fail "Prometheus metrics" "capture failed (non-fatal)"
    log.warn "Prometheus metrics capture failed, continuing..."
  fi
else
  log.verbose "Prometheus metrics collection skipped (--skip-prometheus-metrics)."
fi

if [[ "$MIGRATION_FAILED" == "true" ]]; then
  log.info ""
  log.error "Migration failed but metrics were captured."
  exit 1
fi

# ══════════════════════════════════════════════════════════════
# [6/6] POST-MIGRATION CHECK
# ══════════════════════════════════════════════════════════════

step.begin "[6/6] POST-MIGRATION CHECK"
"${SCRIPT_DIR}/post-migration-check.sh" \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$RUN_REPORT_DIR" \
  --pre-migration-file "$PRE_FILE" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout "$POST_SSH_READY_TIMEOUT" \
  --chaos-scenario "$CHAOS_SCENARIO"
step.end "PASS"

# ── Pipeline footer ───────────────────────────────────────────
PIPELINE_ELAPSED=$(( $(date +%s) - PIPELINE_START_TIME ))
PIPELINE_MIN=$((PIPELINE_ELAPSED / 60))
PIPELINE_SEC=$((PIPELINE_ELAPSED % 60))

log.banner "E2E Completed"
log.info "  VM:        ${VM_NAME}"
[[ -n "$CHAOS_SCENARIO" ]] && log.info "  Chaos:     ${CHAOS_SCENARIO}"
log.info "  Reports:   ${RUN_REPORT_DIR}"
log.info "  Duration:  ${PIPELINE_MIN}m${PIPELINE_SEC}s"
log.info ""

log.cleanup_failure_context
