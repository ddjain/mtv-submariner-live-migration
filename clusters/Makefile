##
## VM Migration Toolkit
##
## Source cluster = BLUE, Target cluster = GREEN
##
## Usage:
##   make create-vm      Create a VM on source (blue) cluster
##   make setup          Setup workloads on source (blue) VM
##   make pre-check      Run pre-migration checklist on source (blue)
##   make migrate-vm     Create migration plan and trigger live migration
##   make post-check     Run post-migration checklist on target (green)
##   make run-e2e        Full pipeline: create-vm -> setup -> pre-check -> migrate -> post-check
##   make clean-vms      Delete ALL VMs from both clusters
##   make clean-migrations  Delete ALL Migration/Plan resources
##   make clean-all      Delete ALL VMs + migrations from both clusters
##   make help           Show this help
##

SHELL := /bin/bash

# ──────────────────────────────────────────────
# Cluster Configuration
# ──────────────────────────────────────────────

SOURCE_KUBECONFIG := $(CURDIR)/source-cluster/auth/kubeconfig
TARGET_KUBECONFIG := $(CURDIR)/target-cluster/auth/kubeconfig

VM_NAME    ?= nexus-vm
NAMESPACE  ?= default
SSH_KEY    ?= $(HOME)/.ssh/id_rsa
SSH_USER   ?= centos
OUTPUT_DIR := $(CURDIR)/scripts/reports

# Optional: pass to setup/pre-check/post-check for unattended SSH (e.g. -o StrictHostKeyChecking=accept-new)
LOCAL_SSH_OPTS ?=

# Optional: fixed VM name for make run-e2e (otherwise a random prefix-base-vm is generated)
VM_NAME_OVERRIDE ?=

# Max seconds to wait for guest SSH after VM Ready (cloud-init / sshd); see setup-vm-workloads.sh
SSH_READY_TIMEOUT ?= 600
# If the shell exports SSH_READY_TIMEOUT= (empty), ?= keeps it empty and breaks --ssh-ready-timeout; coerce:
SSH_READY_TIMEOUT_EFFECTIVE := $(or $(SSH_READY_TIMEOUT),600)

# Seconds to wait after workload setup before pre-migration check (default 30)
STABILIZE_WAIT ?= 120

SCRIPTS_DIR   := $(CURDIR)/scripts
TEMPLATE_DIR  := $(CURDIR)/../templates
GENERATED_DIR := $(CURDIR)/scripts/generated

# Auto-detect latest pre-migration file for comparison
PRE_FILE ?= $(shell ls -t $(OUTPUT_DIR)/pre-migration-$(VM_NAME)-*.json 2>/dev/null | head -1)

# ──────────────────────────────────────────────
# VM Lifecycle
# ──────────────────────────────────────────────

.PHONY: create-vm
create-vm: ## Create a VM on source cluster from template
	@$(SCRIPTS_DIR)/create-vm.sh \
		--kubeconfig $(SOURCE_KUBECONFIG) \
		--vm $(VM_NAME) \
		--namespace $(NAMESPACE) \
		--ssh-key $(SSH_KEY).pub \
		--template $(TEMPLATE_DIR)/vm.yaml.template \
		--output-dir $(GENERATED_DIR)

.PHONY: migrate-vm
migrate-vm: ## Create migration plan and trigger live migration
	@$(SCRIPTS_DIR)/migrate-vm.sh \
		--kubeconfig $(SOURCE_KUBECONFIG) \
		--vm $(VM_NAME) \
		--namespace $(NAMESPACE) \
		--template-dir $(TEMPLATE_DIR) \
		--output-dir $(GENERATED_DIR)

.PHONY: delete-vm
delete-vm: ## Delete a VM from source cluster
	@echo "Deleting VM '$(VM_NAME)' from source cluster..."
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl delete vm $(VM_NAME) -n $(NAMESPACE) --ignore-not-found
	@echo "Done."

.PHONY: clean-vms
clean-vms: ## Delete ALL VMs, VMIs, and DataVolumes from both clusters
	@echo "=== Cleaning VMs from SOURCE (Blue) ==="
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl delete vm --all -n $(NAMESPACE) --ignore-not-found
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl delete vmi --all -n $(NAMESPACE) --ignore-not-found
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl delete dv --all -n $(NAMESPACE) --ignore-not-found
	@echo ""
	@echo "=== Cleaning VMs from TARGET (Green) ==="
	@KUBECONFIG=$(TARGET_KUBECONFIG) kubectl delete vm --all -n $(NAMESPACE) --ignore-not-found
	@KUBECONFIG=$(TARGET_KUBECONFIG) kubectl delete vmi --all -n $(NAMESPACE) --ignore-not-found
	@KUBECONFIG=$(TARGET_KUBECONFIG) kubectl delete dv --all -n $(NAMESPACE) --ignore-not-found
	@echo "Done."

.PHONY: clean-migrations
clean-migrations: ## Delete ALL Migration and Plan resources from openshift-mtv
	@echo "=== Cleaning Migrations ==="
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl delete migration --all -n openshift-mtv --ignore-not-found
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl delete plan --all -n openshift-mtv --ignore-not-found
	@echo "Done."

.PHONY: clean-all
clean-all: clean-migrations clean-vms ## Delete ALL VMs and migration resources from both clusters

.PHONY: run-e2e
run-e2e: ## Full e2e: random VM (or VM_NAME_OVERRIDE), create, setup, pre-check, migrate, wait, post-check
	@$(SCRIPTS_DIR)/run-e2e.sh \
		--source-kubeconfig $(SOURCE_KUBECONFIG) \
		--target-kubeconfig $(TARGET_KUBECONFIG) \
		--ssh-key $(SSH_KEY) \
		--ssh-user $(SSH_USER) \
		--namespace $(NAMESPACE) \
		--template-dir $(TEMPLATE_DIR) \
		--output-dir $(GENERATED_DIR) \
		--report-dir $(OUTPUT_DIR) \
		$(if $(VM_NAME_OVERRIDE),--vm $(VM_NAME_OVERRIDE),) \
		$(if $(LOCAL_SSH_OPTS),--local-ssh-opts "$(LOCAL_SSH_OPTS)",) \
		--ssh-ready-timeout $(SSH_READY_TIMEOUT_EFFECTIVE) \
		--stabilize-wait $(STABILIZE_WAIT)

# ──────────────────────────────────────────────
# Validation & Workloads
# ──────────────────────────────────────────────

.PHONY: setup
setup: ## Setup workloads on source cluster VM
	@$(SCRIPTS_DIR)/setup-vm-workloads.sh \
		--kubeconfig $(SOURCE_KUBECONFIG) \
		--vm $(VM_NAME) \
		--namespace $(NAMESPACE) \
		--ssh-key $(SSH_KEY) \
		--ssh-user $(SSH_USER) \
		--ssh-ready-timeout $(SSH_READY_TIMEOUT_EFFECTIVE) \
		$(if $(LOCAL_SSH_OPTS),--local-ssh-opts "$(LOCAL_SSH_OPTS)",)

.PHONY: pre-check
pre-check: ## Run pre-migration checklist on source cluster
	@mkdir -p $(OUTPUT_DIR)
	@$(SCRIPTS_DIR)/pre-migration-check.sh \
		--kubeconfig $(SOURCE_KUBECONFIG) \
		--vm $(VM_NAME) \
		--namespace $(NAMESPACE) \
		--ssh-key $(SSH_KEY) \
		--ssh-user $(SSH_USER) \
		--output-dir $(OUTPUT_DIR) \
		$(if $(LOCAL_SSH_OPTS),--local-ssh-opts "$(LOCAL_SSH_OPTS)",)

.PHONY: post-check
post-check: ## Run post-migration checklist on target cluster (auto-picks latest pre-check)
	@mkdir -p $(OUTPUT_DIR)
	@$(SCRIPTS_DIR)/post-migration-check.sh \
		--kubeconfig $(TARGET_KUBECONFIG) \
		--vm $(VM_NAME) \
		--namespace $(NAMESPACE) \
		--ssh-key $(SSH_KEY) \
		--ssh-user $(SSH_USER) \
		--output-dir $(OUTPUT_DIR) \
		$(if $(PRE_FILE),--pre-migration-file $(PRE_FILE),) \
		$(if $(LOCAL_SSH_OPTS),--local-ssh-opts "$(LOCAL_SSH_OPTS)",)

# ──────────────────────────────────────────────
# Log Capture
# ──────────────────────────────────────────────

.PHONY: capture-logs
capture-logs: ## Capture pod logs, watches & events from both clusters during migration
	@$(SCRIPTS_DIR)/capture-migration-logs.sh \
		--vm $(VM_NAME) \
		--namespace $(NAMESPACE) \
		$(if $(DURATION),--duration $(DURATION),)

# ──────────────────────────────────────────────
# Status & Access
# ──────────────────────────────────────────────

.PHONY: status
status: ## Show VM status on both clusters
	@echo "=== SOURCE (Blue) ==="
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl get vm $(VM_NAME) -n $(NAMESPACE) 2>/dev/null || echo "  VM not found"
	@KUBECONFIG=$(SOURCE_KUBECONFIG) kubectl get vmi $(VM_NAME) -n $(NAMESPACE) 2>/dev/null || true
	@echo ""
	@echo "=== TARGET (Green) ==="
	@KUBECONFIG=$(TARGET_KUBECONFIG) kubectl get vm $(VM_NAME) -n $(NAMESPACE) 2>/dev/null || echo "  VM not found"
	@KUBECONFIG=$(TARGET_KUBECONFIG) kubectl get vmi $(VM_NAME) -n $(NAMESPACE) 2>/dev/null || true

.PHONY: ssh-source
ssh-source: ## SSH into VM on source cluster
	KUBECONFIG=$(SOURCE_KUBECONFIG) virtctl ssh $(SSH_USER)@vm/$(VM_NAME) \
		--namespace $(NAMESPACE) --identity-file=$(SSH_KEY)

.PHONY: ssh-target
ssh-target: ## SSH into VM on target cluster
	KUBECONFIG=$(TARGET_KUBECONFIG) virtctl ssh $(SSH_USER)@vm/$(VM_NAME) \
		--namespace $(NAMESPACE) --identity-file=$(SSH_KEY)

# ──────────────────────────────────────────────
# Reports
# ──────────────────────────────────────────────

.PHONY: list-reports
list-reports: ## List all generated reports
	@ls -lt $(OUTPUT_DIR)/*.json 2>/dev/null || echo "No reports found."

.PHONY: clean-reports
clean-reports: ## Remove all generated reports
	@rm -f $(OUTPUT_DIR)/*.json && echo "Reports cleaned."

# ──────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "VM Migration Toolkit"
	@echo "===================="
	@echo ""
	@echo "  Source (Blue)  : $(SOURCE_KUBECONFIG)"
	@echo "  Target (Green) : $(TARGET_KUBECONFIG)"
	@echo "  VM             : $(VM_NAME) (ns: $(NAMESPACE))"
	@echo ""
	@echo "Workflow:"
	@echo "  make run-e2e        # full pipeline (random VM name or VM_NAME_OVERRIDE=...)"
	@echo "  --- or step by step ---"
	@echo "  1. make create-vm   # create VM on source cluster"
	@echo "  2. make setup       # install workloads on source VM"
	@echo "  3. make pre-check   # capture baseline before migration"
	@echo "  4. make migrate-vm  # create plan and trigger live migration"
	@echo "  5. make post-check  # validate on target, auto-compares with latest pre-check"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Override variables: VM_NAME=x NAMESPACE=x SSH_KEY=x SSH_USER=x"
	@echo "  LOCAL_SSH_OPTS='-o StrictHostKeyChecking=accept-new' for unattended SSH on setup/pre/post-check"
	@echo "  VM_NAME_OVERRIDE=name for make run-e2e (fixed VM instead of random)"
	@echo "  SSH_READY_TIMEOUT=900  seconds to wait for guest SSH after VM Ready (default 600)"
	@echo "  STABILIZE_WAIT=60      seconds to wait after workload setup before pre-check (default 30)"
	@echo ""

.DEFAULT_GOAL := help
