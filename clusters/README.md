# VM Migration Toolkit

Automated end-to-end cross-cluster live migration of KubeVirt VMs using MTV (Forklift) and Submariner.

## Prerequisites

### CLI Tools

- `kubectl` / `oc`
- `virtctl` — [KubeVirt CLI](https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/)
- `jq`
- `bash` ≥ 4.x

### Cluster Setup

Two OpenShift clusters (blue = source, green = target) with the following operators installed on **both**:

- OpenShift Virtualization (CNV)
- Migration Toolkit for Virtualization (MTV / Forklift)
- Submariner (cross-cluster networking)

MTV must be pre-configured on the **source** cluster with:

- A `Provider` for the target cluster (named `green-cluster` in `openshift-mtv`)
- A `NetworkMap` (named `blue-green-network-map` in `openshift-mtv`)
- A `StorageMap` (named `blue-green-storage-map` in `openshift-mtv`)

### Local Configuration

1. **Kubeconfigs** — place them at (or symlink to):

   ```
   clusters/source-cluster/auth/kubeconfig
   clusters/target-cluster/auth/kubeconfig
   ```

2. **SSH key pair** — default is `~/.ssh/id_rsa` (override with `SSH_KEY=`). The public key (`id_rsa.pub`) is injected into the VM via cloud-init.

## Quick Start

```bash
cd clusters

# Full automated pipeline (random VM name, unattended SSH)
make run-e2e

# Or step-by-step
make create-vm    VM_NAME=my-vm
make setup        VM_NAME=my-vm
make pre-check    VM_NAME=my-vm
make migrate-vm   VM_NAME=my-vm
make post-check   VM_NAME=my-vm
```

## Makefile Variables

| Variable | Default | Description |
|---|---|---|
| `VM_NAME` | `nexus-vm` | VM name for individual targets |
| `VM_NAME_OVERRIDE` | *(random)* | Fixed VM name for `run-e2e` |
| `NAMESPACE` | `default` | Kubernetes namespace |
| `SSH_KEY` | `~/.ssh/id_rsa` | SSH private key path |
| `SSH_USER` | `centos` | Guest OS user |
| `LOCAL_SSH_OPTS` | | SSH options (e.g. `-o StrictHostKeyChecking=accept-new`) |
| `SSH_READY_TIMEOUT` | `600` | Seconds to wait for guest SSH after VM boots |

## Directory Structure

```
clusters/
├── Makefile                     # Orchestration targets
├── README.md
├── source-cluster/auth/kubeconfig   # (git-ignored)
├── target-cluster/auth/kubeconfig   # (git-ignored)
└── scripts/
    ├── create-vm.sh             # Create VM from template
    ├── setup-vm-workloads.sh    # Install workloads via SSH
    ├── pre-migration-check.sh   # Capture baseline state
    ├── migrate-vm.sh            # Create plan + trigger migration
    ├── post-migration-check.sh  # Validate on target cluster
    ├── run-e2e.sh               # Full pipeline orchestrator
    ├── capture-migration-logs.sh
    ├── generated/               # Rendered manifests (git-ignored)
    └── reports/                 # Check results JSON (git-ignored)
```
