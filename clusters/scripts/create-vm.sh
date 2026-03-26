#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create a VirtualMachine on an OpenShift cluster from a template.

Required:
  --kubeconfig PATH    Path to cluster kubeconfig
  --vm NAME            VM name
  --ssh-key PATH       Path to SSH public key file

Optional:
  --namespace NS       Target namespace (default: default)
  --template PATH      Path to vm.yaml.template (auto-detected if not set)
  --output-dir DIR     Directory to save rendered manifest (auto-detected)
  --dry-run            Render the manifest but do not apply

EOF
  exit 1
}

KUBECONFIG=""
VM_NAME=""
NAMESPACE="default"
SSH_KEY=""
TEMPLATE=""
OUTPUT_DIR=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)  KUBECONFIG="$2"; shift 2 ;;
    --vm)          VM_NAME="$2"; shift 2 ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --ssh-key)     SSH_KEY="$2"; shift 2 ;;
    --template)    TEMPLATE="$2"; shift 2 ;;
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)     usage ;;
    *)             echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]]    && { echo "ERROR: --vm is required"; usage; }
[[ -z "$SSH_KEY" ]]    && { echo "ERROR: --ssh-key is required"; usage; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$TEMPLATE" ]]; then
  TEMPLATE="${SCRIPT_DIR}/../../templates/vm.yaml.template"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/generated"
fi

[[ ! -f "$TEMPLATE" ]]  && { echo "ERROR: Template not found: $TEMPLATE"; exit 1; }
[[ ! -f "$SSH_KEY" ]]   && { echo "ERROR: SSH public key not found: $SSH_KEY"; exit 1; }

SSH_PUB_KEY="$(cat "$SSH_KEY")"

RENDERED=$(sed \
  -e "s|REPLACE_VM_NAME|${VM_NAME}|g" \
  -e "s|REPLACE_NAMESPACE|${NAMESPACE}|g" \
  -e "s|REPLACE_SSH_PUBLIC_KEY|${SSH_PUB_KEY}|g" \
  "$TEMPLATE")

mkdir -p "$OUTPUT_DIR"
OUTFILE="${OUTPUT_DIR}/${VM_NAME}-vm.yaml"
echo "$RENDERED" > "$OUTFILE"
echo "Rendered manifest saved to ${OUTFILE}"

if [[ "$DRY_RUN" == true ]]; then
  echo "$RENDERED"
  exit 0
fi

echo "Creating VM '${VM_NAME}' in namespace '${NAMESPACE}'..."
KUBECONFIG="$KUBECONFIG" kubectl apply -f "$OUTFILE"

echo ""
echo "Waiting for VM to be ready..."
KUBECONFIG="$KUBECONFIG" kubectl wait vm/"$VM_NAME" \
  -n "$NAMESPACE" --for=condition=Ready --timeout=300s

echo ""
echo "VM '${VM_NAME}' created successfully."
KUBECONFIG="$KUBECONFIG" kubectl get vm,vmi "$VM_NAME" -n "$NAMESPACE"
