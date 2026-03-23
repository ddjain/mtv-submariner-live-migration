# Cross-Cluster Live Migration (CCLM) on OpenShift

Step-by-step guide to set up cross-cluster live migration of VirtualMachines between two OpenShift clusters (**blue-cluster** and **green-cluster**) using MTV/Forklift and Submariner.

## Overview

This guide enables live migration of running VMs from blue-cluster (source) to green-cluster (target) with zero downtime, using:

- **OpenShift Virtualization (CNV)** -- VM lifecycle management
- **Migration Toolkit for Virtualization (MTV/Forklift)** -- migration orchestration
- **Submariner** -- cross-cluster IPsec networking tunnel

### Architecture

```
BLUE CLUSTER (Source)                   GREEN CLUSTER (Target)
+--------------------------+            +--------------------------+
| Pod CIDR: 10.128.0.0/14 |            | Pod CIDR: 10.224.0.0/14  |
| Svc CIDR: 172.30.0.0/16 |<==IPsec==> | Svc CIDR: 172.24.0.0/16  |
| [vm-name] --> VMIM       |   Tunnel   | [vm-name] <-- Migrated   |
| Submariner Gateway       |            | Submariner Gateway       |
+--------------------------+            +--------------------------+

Migration Flow:
Operators -> Feature Gates -> Submariner -> RBAC/Providers -> Maps -> Plan -> Migrate
```

## Prerequisites

- Two OpenShift 4.21+ clusters (blue-cluster and green-cluster)
- **Non-overlapping** Pod, Service, and Machine CIDRs between clusters
- `oc` CLI installed
- `subctl` CLI installed (`curl -Ls https://get.submariner.io | bash`)
- `yq` CLI installed (`brew install yq`)
- Cluster admin access on both clusters
- Kubeconfig files for both clusters

### Set Environment Variables

```bash
export KUBECONFIG_BLUE=<path-to-blue-cluster-kubeconfig>
export KUBECONFIG_GREEN=<path-to-green-cluster-kubeconfig>
```

### Verify CIDR Requirements

Submariner requires non-overlapping CIDRs. Verify with:

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc get network cluster -o yaml
KUBECONFIG=$KUBECONFIG_GREEN oc get network cluster -o yaml
```

| Network | Blue Cluster | Green Cluster | Overlap? |
|---------|-------------|---------------|----------|
| Pod CIDR | 10.128.0.0/14 | 10.224.0.0/14 | No |
| Service CIDR | 172.30.0.0/16 | 172.24.0.0/16 | No |
| Machine CIDR | 10.0.0.0/16 | 10.2.0.0/16 | No |

> If CIDRs overlap, rebuild one cluster with different CIDRs before proceeding.

### Cloud Networking (GCP)

If clusters are on separate VPC networks, you need VPC peering and firewall rules.

**VPC Peering:**

```bash
gcloud compute networks peerings create blue-to-green \
  --project=<PROJECT_ID> \
  --network=<BLUE_VPC_NETWORK> \
  --peer-network=<GREEN_VPC_NETWORK>

gcloud compute networks peerings create green-to-blue \
  --project=<PROJECT_ID> \
  --network=<GREEN_VPC_NETWORK> \
  --peer-network=<BLUE_VPC_NETWORK>
```

**Firewall rules** (allow Submariner ports on both VPCs):

```bash
# Blue VPC: allow traffic from green machine CIDR
gcloud compute firewall-rules create blue-submariner-in \
  --project=<PROJECT_ID> \
  --network=<BLUE_VPC_NETWORK> \
  --allow=udp:500,udp:4500,udp:4800,esp \
  --source-ranges=<GREEN_MACHINE_CIDR>

# Green VPC: allow traffic from blue machine CIDR
gcloud compute firewall-rules create green-submariner-in \
  --project=<PROJECT_ID> \
  --network=<GREEN_VPC_NETWORK> \
  --allow=udp:500,udp:4500,udp:4800,esp \
  --source-ranges=<BLUE_MACHINE_CIDR>
```

---

## Phase 1: Operator Installation

Install on **both** blue-cluster and green-cluster from OperatorHub:

| Operator | Channel | Namespace |
|----------|---------|-----------|
| OpenShift Virtualization (`kubevirt-hyperconverged`) | `stable` | `openshift-cnv` |
| Migration Toolkit for Virtualization (`mtv-operator`) | `release-v2.11` | `openshift-mtv` |

After install, create operator instances:
- **OpenShift Virtualization**: Create `HyperConverged` CR from the operator page
- **MTV**: `ForkliftController` CR is auto-created by the operator

### Verify Operators

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc get csv -n openshift-cnv
KUBECONFIG=$KUBECONFIG_BLUE oc get csv -n openshift-mtv
KUBECONFIG=$KUBECONFIG_GREEN oc get csv -n openshift-cnv
KUBECONFIG=$KUBECONFIG_GREEN oc get csv -n openshift-mtv
# All should show Phase: Succeeded
```

### Enable Feature Gates (both clusters)

**1. Enable decentralized live migration (CNV):**

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv --type json \
  -p '[{"op":"replace","path":"/spec/featureGates/decentralizedLiveMigration","value":true}]'

KUBECONFIG=$KUBECONFIG_GREEN oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv --type json \
  -p '[{"op":"replace","path":"/spec/featureGates/decentralizedLiveMigration","value":true}]'
```

**2. Wait for virt-synchronization-controller pods (auto-started after patching):**

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc get pod -n openshift-cnv | grep virt-synchronization
KUBECONFIG=$KUBECONFIG_GREEN oc get pod -n openshift-cnv | grep virt-synchronization
# Both should show 2 pods Running
```

**3. Enable OCP live migration feature in MTV:**

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc patch ForkliftController forklift-controller \
  -n openshift-mtv --type json \
  -p '[{"op":"add","path":"/spec/feature_ocp_live_migration","value":"true"}]'

KUBECONFIG=$KUBECONFIG_GREEN oc patch ForkliftController forklift-controller \
  -n openshift-mtv --type json \
  -p '[{"op":"add","path":"/spec/feature_ocp_live_migration","value":"true"}]'
```

### Verify Feature Gates

```bash
# decentralizedLiveMigration (expect: true)
KUBECONFIG=$KUBECONFIG_BLUE oc get hco kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}' && echo ""
KUBECONFIG=$KUBECONFIG_GREEN oc get hco kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}' && echo ""

# feature_ocp_live_migration (expect: true)
KUBECONFIG=$KUBECONFIG_BLUE oc get ForkliftController forklift-controller -n openshift-mtv \
  -o jsonpath='{.spec.feature_ocp_live_migration}' && echo ""
KUBECONFIG=$KUBECONFIG_GREEN oc get ForkliftController forklift-controller -n openshift-mtv \
  -o jsonpath='{.spec.feature_ocp_live_migration}' && echo ""
```

---

## Phase 2: Submariner Deployment

### 1. Deploy Broker on Blue Cluster

```bash
subctl deploy-broker --kubeconfig $KUBECONFIG_BLUE
```

### 2. Label Gateway Nodes (one worker per cluster)

```bash
# Blue cluster (auto-selects first worker node)
KUBECONFIG=$KUBECONFIG_BLUE oc label node \
  $(KUBECONFIG=$KUBECONFIG_BLUE oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].metadata.name}') \
  submariner.io/gateway=true

# Green cluster
KUBECONFIG=$KUBECONFIG_GREEN oc label node \
  $(KUBECONFIG=$KUBECONFIG_GREEN oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].metadata.name}') \
  submariner.io/gateway=true
```

### 3. Join Blue Cluster to Broker

```bash
subctl join broker-info.subm \
  --kubeconfig $KUBECONFIG_BLUE \
  --clusterid blue-cluster \
  --cable-driver libreswan \
  --health-check=true --natt=false
```

### 4. Join Green Cluster to Broker

```bash
subctl join broker-info.subm \
  --kubeconfig $KUBECONFIG_GREEN \
  --clusterid green-cluster \
  --cable-driver libreswan \
  --health-check=true --natt=false
```

> Run steps 3 and 4 sequentially. Wait for blue to complete before joining green.

### 5. Verify Connectivity

```bash
# Check connection status (expect: connected)
subctl show connections --kubeconfig $KUBECONFIG_BLUE

# Check networks on both clusters
subctl show networks --kubeconfig $KUBECONFIG_BLUE
subctl show networks --kubeconfig $KUBECONFIG_GREEN

# Full connectivity test
subctl verify \
  --kubeconfig $KUBECONFIG_BLUE \
  --toconfig $KUBECONFIG_GREEN \
  --only connectivity --verbose
```

---

## Phase 3: MTV Cross-Cluster Configuration

### Step 1: Create ClusterRole (both clusters)

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/01_mtv-clusterrole.yaml
KUBECONFIG=$KUBECONFIG_GREEN oc apply -f manifests/01_mtv-clusterrole.yaml
```

### Step 2: Create ServiceAccount (both clusters)

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc create serviceaccount mtv-migration-sa -n openshift-mtv
KUBECONFIG=$KUBECONFIG_GREEN oc create serviceaccount mtv-migration-sa -n openshift-mtv
```

### Step 3: Create ClusterRoleBinding (both clusters)

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc create clusterrolebinding mtv-migration-sa-binding \
  --clusterrole=live-migration-role \
  --serviceaccount=openshift-mtv:mtv-migration-sa

KUBECONFIG=$KUBECONFIG_GREEN oc create clusterrolebinding mtv-migration-sa-binding \
  --clusterrole=live-migration-role \
  --serviceaccount=openshift-mtv:mtv-migration-sa
```

### Step 4: Create Token Secrets (both clusters)

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/02_mtv-sa-token-secret.yaml
KUBECONFIG=$KUBECONFIG_GREEN oc apply -f manifests/02_mtv-sa-token-secret.yaml
```

### Step 5: Extract Green Cluster Credentials

```bash
mkdir -p secrets/green-cluster

# Extract token
KUBECONFIG=$KUBECONFIG_GREEN oc get secret mtv-migration-sa-token -n openshift-mtv \
  -o jsonpath='{.data.token}' | base64 --decode > secrets/green-cluster/token.txt

# Extract CA cert
KUBECONFIG=$KUBECONFIG_GREEN oc get cm kube-root-ca.crt -n openshift-mtv \
  -o jsonpath='{.data.ca\.crt}' > secrets/green-cluster/ca.crt
```

### Step 6: Generate and Apply Provider Secret (blue-cluster only)

```bash
cat > manifests/07_green-provider-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: green-cluster-secret
  namespace: openshift-mtv
type: Opaque
stringData:
  token: "$(cat secrets/green-cluster/token.txt)"
  cacert: |
$(sed 's/^/    /' secrets/green-cluster/ca.crt)
EOF

KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/07_green-provider-secret.yaml
```

> The generated `07_green-provider-secret.yaml` contains real credentials. It is excluded from git by `.gitignore`. See [templates/provider-secret.yaml.template](templates/provider-secret.yaml.template) for the safe template.

### Step 7: Apply Provider CR (blue-cluster only)

Update the URL in `manifests/07_provider.yaml` to match your green cluster:

```bash
yq -i '.spec.url = "https://api.<green-cluster-domain>:6443"' manifests/07_provider.yaml

KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/07_provider.yaml
```

### Step 8: Verify Providers

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc get provider -n openshift-mtv
# Both "host" and "green-cluster" should show:
#   Ready=True, Connected=True, Inventory=True
```

> Do NOT proceed until both providers show Ready=True and Inventory=True.

---

## Phase 4: Network and Storage Mapping

### Step 1: Apply NetworkMap (blue-cluster only)

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/03_network-map.yaml
```

**Key fields in `03_network-map.yaml`:**

| Field | Value | Must match? | Notes |
|-------|-------|-------------|-------|
| `spec.provider.source.name` | `host` | Yes | Auto-created local provider. Always `host`. |
| `spec.provider.destination.name` | `green-cluster` | Yes | Must match Provider CR name from Phase 3. |
| `spec.map[].source.type` | `pod` | Yes | Only `type: pod`. No `name` or `namespace`. |
| `spec.map[].destination.type` | `pod` | Yes | Only `type: pod`. No `name` or `namespace`. |

### Step 2: Apply StorageMap (blue-cluster only)

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/04_storage-map.yaml
```

**Key fields in `04_storage-map.yaml`:**

| Field | Value | Must match? | Notes |
|-------|-------|-------------|-------|
| `spec.provider.destination.name` | `green-cluster` | Yes | Must match Provider CR name. |
| `spec.map[].source.name` | `standard-csi` | Yes | StorageClass on blue. Run `oc get sc` to verify. |
| `spec.map[].destination.storageClass` | `standard-csi` | Yes | Must use `storageClass:`, **not** `name:`. |

### Step 3: Verify

```bash
KUBECONFIG=$KUBECONFIG_BLUE oc get networkmap,storagemap -n openshift-mtv
# Both should show Ready=True
```

---

## Phase 5: VM Creation and Live Migration

### Option A: Via CLI

```bash
# Apply migration plan
KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/05_migration-plan.yaml

# Wait for validation (Ready=True)
KUBECONFIG=$KUBECONFIG_BLUE oc get plan -n openshift-mtv -w

# Trigger migration
KUBECONFIG=$KUBECONFIG_BLUE oc apply -f manifests/06_migration.yaml

# Monitor progress (Initialize -> PrepareTarget -> Synchronization -> Completed)
KUBECONFIG=$KUBECONFIG_BLUE oc get migration -n openshift-mtv -w

# Watch VM appear on green-cluster
KUBECONFIG=$KUBECONFIG_GREEN oc get vm,vmi -n default -w
```

### Option B: Via OpenShift Console

1. Open the OpenShift Console on **blue-cluster**
2. Navigate to **Migration for Virtualization** > **Create Migration Plan**
3. Select source provider: `host`, target provider: `green-cluster`
4. Select the VM(s) to migrate
5. Select existing network map and storage map
6. Choose **Live migration**
7. Create and start the plan

### Expected Timeline

| Stage | Duration |
|-------|----------|
| Initialize | ~1 second |
| PrepareTarget | ~10-15 seconds |
| Synchronization | ~4-5 minutes (30Gi VM) |
| **Total** | **~5 minutes** |

### Post-Migration Verification

```bash
# Blue cluster: VM should be stopped
KUBECONFIG=$KUBECONFIG_BLUE oc get vm -n default

# Green cluster: VM should be running
KUBECONFIG=$KUBECONFIG_GREEN oc get vm,vmi -n default

# Migration status (expect: phase: Completed)
KUBECONFIG=$KUBECONFIG_BLUE oc get migration -n openshift-mtv
```

---

## Troubleshooting

| Issue | Symptom | Fix |
|-------|---------|-----|
| CIDR overlap | `subctl verify` routing errors | Rebuild cluster with non-overlapping CIDRs |
| NetworkMap not Ready | "Source network not found" | Use only `type: pod`, remove any `name`/`namespace` |
| StorageMap error | "Source storage: either ID or Name required" | Use `storageClass:` not `name:` in destination |
| Provider not Ready | `Ready=False` | Verify token, CA cert, and API URL in provider secret |
| Submariner not connecting | Gateway stuck in "connecting" | Check VPC peering and firewall rules (UDP 500, 4500, 4800, ESP) |
| Migration stuck | Stays in Synchronization >10 min | Check `oc get pods -n submariner-operator` and `oc get vmim -A` |

## Manifest Reference

| File | Purpose | Apply to |
|------|---------|----------|
| `01_mtv-clusterrole.yaml` | RBAC for MTV service account | Both clusters |
| `02_mtv-sa-token-secret.yaml` | Long-lived SA token secret | Both clusters |
| `03_network-map.yaml` | Pod network mapping | Blue cluster only |
| `04_storage-map.yaml` | Storage class mapping | Blue cluster only |
| `05_migration-plan.yaml` | Migration plan definition | Blue cluster only |
| `06_migration.yaml` | Migration trigger | Blue cluster only |
| `07_provider.yaml` | Green cluster provider CR | Blue cluster only |

> `07_green-provider-secret.yaml` is generated at runtime with real credentials. Use `templates/provider-secret.yaml.template` as a starting point. Never commit the generated file.

## Tested With

- OpenShift 4.21.2
- OpenShift Virtualization (CNV) 4.21.1
- MTV Operator 2.11.1
- Submariner 0.23.1
- GCP (us-central1), OVNKubernetes, libreswan
