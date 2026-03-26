#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create a migration Plan and trigger a live Migration for a VM.

Required:
  --kubeconfig PATH    Path to source cluster kubeconfig

Optional:
  --vm NAME            VM name (default: earth-vm)
  --namespace NS       VM namespace (default: default)
  --template-dir DIR   Directory containing .yaml.template files (auto-detected)
  --output-dir DIR     Directory to save rendered manifests (auto-detected)
  --plan-only          Apply the Plan but do not trigger the Migration
  --dry-run            Render manifests but do not apply

EOF
  exit 1
}

KUBECONFIG=""
VM_NAME="earth-vm"
NAMESPACE="default"
TEMPLATE_DIR=""
OUTPUT_DIR=""
PLAN_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)    KUBECONFIG="$2"; shift 2 ;;
    --vm)            VM_NAME="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2"; shift 2 ;;
    --template-dir)  TEMPLATE_DIR="$2"; shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
    --plan-only)     PLAN_ONLY=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)       usage ;;
    *)               echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG" ]] && { echo "ERROR: --kubeconfig is required"; usage; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$TEMPLATE_DIR" ]]; then
  TEMPLATE_DIR="${SCRIPT_DIR}/../../templates"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/generated"
fi

PLAN_TEMPLATE="${TEMPLATE_DIR}/migration-plan.yaml.template"
MIGRATION_TEMPLATE="${TEMPLATE_DIR}/migration.yaml.template"

[[ ! -f "$PLAN_TEMPLATE" ]]      && { echo "ERROR: Template not found: $PLAN_TEMPLATE"; exit 1; }
[[ ! -f "$MIGRATION_TEMPLATE" ]] && { echo "ERROR: Template not found: $MIGRATION_TEMPLATE"; exit 1; }

render() {
  sed \
    -e "s|REPLACE_VM_NAME|${VM_NAME}|g" \
    -e "s|REPLACE_NAMESPACE|${NAMESPACE}|g" \
    "$1"
}

RENDERED_PLAN="$(render "$PLAN_TEMPLATE")"
RENDERED_MIGRATION="$(render "$MIGRATION_TEMPLATE")"

mkdir -p "$OUTPUT_DIR"
PLAN_FILE="${OUTPUT_DIR}/${VM_NAME}-migration-plan.yaml"
MIGRATION_FILE="${OUTPUT_DIR}/${VM_NAME}-migration.yaml"
echo "$RENDERED_PLAN" > "$PLAN_FILE"
echo "$RENDERED_MIGRATION" > "$MIGRATION_FILE"
echo "Rendered manifests saved to ${OUTPUT_DIR}/"

if [[ "$DRY_RUN" == true ]]; then
  echo "--- # Plan"
  echo "$RENDERED_PLAN"
  echo "---"
  echo "--- # Migration"
  echo "$RENDERED_MIGRATION"
  exit 0
fi

# -- Apply Plan --
echo "Applying migration plan for VM '${VM_NAME}'..."
KUBECONFIG="$KUBECONFIG" kubectl apply -f "$PLAN_FILE"

echo "Waiting for Plan to become Ready..."
KUBECONFIG="$KUBECONFIG" kubectl wait plan/"${VM_NAME}-migration-plan" \
  -n openshift-mtv --for=condition=Ready --timeout=120s
echo "Plan is Ready."

if [[ "$PLAN_ONLY" == true ]]; then
  echo "Plan-only mode. Skipping migration trigger."
  exit 0
fi

# -- Trigger Migration --
echo ""
echo "Triggering migration..."
KUBECONFIG="$KUBECONFIG" kubectl apply -f "$MIGRATION_FILE"

echo ""
echo "Migration '${VM_NAME}-migration' created. Monitor with:"
echo "  KUBECONFIG=${KUBECONFIG} kubectl get migration ${VM_NAME}-migration -n openshift-mtv -w"
