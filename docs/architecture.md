# Cross-Cluster Live Migration (CCLM) Implementation Plan

## Context

This plan enables live migration of VirtualMachines between **blue-cluster** and **green-cluster** using MTV/Forklift and Submariner, based on a proven reference implementation at `/Users/darjain/projects/openshift-gcp/cclm-env` that successfully migrated earth-vm in 5 minutes with zero downtime.

**Why:** Enable cross-cluster VM mobility for disaster recovery, cluster upgrades, and workload rebalancing without service interruption.

**What:** Deploy MTV/Forklift + Submariner to create an IPsec tunnel between clusters, allowing VMs to migrate live while running.

**Reference:** Working implementation in `/Users/darjain/projects/openshift-gcp/cclm-env/` with complete audit trail in `CROSS_CLUSTER_LIVE_MIGRATION_REPORT.md`.

---

## Architecture Overview

```
BLUE CLUSTER (Source)                    GREEN CLUSTER (Target)
api.blue-cluster.cclm-chaos...           api.green-cluster.cclm-chaos...
┌─────────────────────────┐             ┌─────────────────────────┐
│ Pod: 10.128.0.0/14      │             │ Pod: 10.128.0.0/14      │
│ Svc: 172.30.0.0/16      │◄═══IPsec═══►│ Svc: 172.30.0.0/16      │
│ [earth-vm] ──► VMIM     │   Tunnel    │ [earth-vm] ◄── Migrated │
│ Submariner Gateway      │             │ Submariner Gateway      │
└─────────────────────────┘             └─────────────────────────┘

Migration Flow:
Provider Setup → NetworkMap → StorageMap → Plan → Migration → Validation
```

---

## ⚠️ CRITICAL PREREQUISITE: Network CIDR Overlap Detected

**BLOCKER IDENTIFIED:**

Both clusters currently have **IDENTICAL network CIDRs**:
- **Blue Cluster:** Pod CIDR `10.128.0.0/14`, Service CIDR `172.30.0.0/16`
- **Green Cluster:** Pod CIDR `10.128.0.0/14`, Service CIDR `172.30.0.0/16`

**Impact:** Submariner **REQUIRES** non-overlapping CIDRs for cross-cluster routing. This will cause routing conflicts and prevent migration.

**Resolution Options:**

### Option A: Rebuild Green Cluster (RECOMMENDED)
Destroy and recreate green-cluster with non-overlapping CIDRs matching the reference implementation:
```yaml
# green-cluster install-config.yaml
networking:
  clusterNetwork:
  - cidr: 10.224.0.0/14    # Different from blue
    hostPrefix: 23
  serviceNetwork:
  - 172.24.0.0/16          # Different from blue
```

### Option B: Enable Submariner Globalnet (COMPLEX)
Use Globalnet for NAT-based routing (adds overhead, not recommended for production).

**Decision Required:** Choose resolution strategy before proceeding.

**This plan assumes Option A is implemented** (non-overlapping CIDRs).

---

## Implementation Phases

### PHASE 1: Operator Installation (Both Clusters)

**Critical Files to Create:**

**1_hyperconverged_subscription.yaml** - OpenShift Virtualization Operator
- Creates `openshift-cnv` namespace
- Installs kubevirt-hyperconverged operator from Red Hat catalog
- Enables VM support on OpenShift

**2_hyperconverged_instance.yaml** - Enable Live Migration Feature
- Sets `featureGates.decentralizedLiveMigration: true` (CRITICAL)
- Configures live migration timeouts and parallelism
- Required for cross-cluster migration

**3_mtv_subscription.yaml** - MTV/Forklift Operator
- Creates `openshift-mtv` namespace
- Installs mtv-operator v2.11 from Red Hat catalog
- Provides migration orchestration CRDs

**4_forklift_controller.yaml** - Enable MTV Live Migration
- Sets `feature_gates.feature_ocp_live_migration: "true"` (CRITICAL)
- Required for OpenShift-to-OpenShift live migration
- Without this, only warm migration is available

**Commands:**
```bash
# Set kubeconfig paths
export KUBECONFIG_BLUE=blue-cluster/auth/kubeconfig
export KUBECONFIG_GREEN=green-cluster/auth/kubeconfig

# Apply to both clusters
for KC in $KUBECONFIG_BLUE $KUBECONFIG_GREEN; do
  kubectl --kubeconfig=$KC apply -f 1_hyperconverged_subscription.yaml
  kubectl --kubeconfig=$KC apply -f 2_hyperconverged_instance.yaml
  kubectl --kubeconfig=$KC apply -f 3_mtv_subscription.yaml
  kubectl --kubeconfig=$KC apply -f 4_forklift_controller.yaml
done
```

**Validation:**
```bash
# Check operators ready (both clusters)
kubectl --kubeconfig=$KUBECONFIG_BLUE get csv -n openshift-cnv
kubectl --kubeconfig=$KUBECONFIG_BLUE get csv -n openshift-mtv
kubectl --kubeconfig=$KUBECONFIG_GREEN get csv -n openshift-cnv
kubectl --kubeconfig=$KUBECONFIG_GREEN get csv -n openshift-mtv

# Verify feature gates enabled
kubectl --kubeconfig=$KUBECONFIG_BLUE get hco -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}'
# Should output: true
```

---

### PHASE 2: Submariner Deployment

**Purpose:** Establish IPsec tunnel for cross-cluster pod communication.

**Prerequisites:**
- Non-overlapping network CIDRs (see CRITICAL section above)
- UDP ports 500, 4500 open between clusters
- ESP protocol (50) allowed

**Steps:**

1. **Install subctl CLI:**
   ```bash
   curl -Ls https://get.submariner.io | bash
   export PATH=$PATH:~/.local/bin
   subctl version
   ```

2. **Deploy Broker on Blue Cluster:**
   ```bash
   subctl deploy-broker \
     --kubeconfig $KUBECONFIG_BLUE \
     --context $(kubectl --kubeconfig=$KUBECONFIG_BLUE config current-context)

   # Extract broker info
   subctl show broker-info --kubeconfig $KUBECONFIG_BLUE --output broker-info.subm
   ```

3. **Label Gateway Nodes:**
   ```bash
   # Blue cluster (worker-a)
   kubectl --kubeconfig=$KUBECONFIG_BLUE label node blue-cluster-m7ckk-worker-a-tgb6q submariner.io/gateway=true

   # Green cluster (worker-a)
   kubectl --kubeconfig=$KUBECONFIG_GREEN label node green-cluster-xwtf6-worker-a-q4t8l submariner.io/gateway=true
   ```

4. **Join Clusters to Broker:**
   ```bash
   # Join blue cluster
   subctl join broker-info.subm \
     --kubeconfig $KUBECONFIG_BLUE \
     --clusterid blue-cluster \
     --cable-driver libreswan \
     --health-check=true \
     --natt=false

   # Join green cluster
   subctl join broker-info.subm \
     --kubeconfig $KUBECONFIG_GREEN \
     --clusterid green-cluster \
     --cable-driver libreswan \
     --health-check=true \
     --natt=false
   ```

**Validation:**
```bash
# Verify connectivity (should show 26/26 tests passing)
subctl verify \
  --kubeconfig $KUBECONFIG_BLUE \
  --toconfig $KUBECONFIG_GREEN \
  --only connectivity \
  --verbose

# Check connection status
subctl show connections --kubeconfig $KUBECONFIG_BLUE
# Should show: Connected to green-cluster

# Verify non-overlapping CIDRs detected
subctl show networks --kubeconfig $KUBECONFIG_BLUE
subctl show networks --kubeconfig $KUBECONFIG_GREEN
```

---

### PHASE 3: MTV Cross-Cluster Configuration

**Purpose:** Create authentication and permissions for cross-cluster VM migration.

**Critical Files to Create:**

**6_mtv_clusterrole.yaml** - RBAC Permissions
- Reuse from reference: `/Users/darjain/projects/openshift-gcp/cclm-env/mtv-migration-clusterrole.yaml`
- Grants permissions for VMs, DataVolumes, PVCs, StorageClasses, NetworkAttachmentDefinitions
- Required on both clusters

**7_mtv_serviceaccount.yaml** - Service Account + Token Secret
- Creates `mtv-migration-sa` service account in `openshift-mtv` namespace
- Creates long-lived token secret (not user token)
- Binds ClusterRole to service account
- Required on both clusters

**Commands:**
```bash
# Apply RBAC and service accounts to both clusters
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 6_mtv_clusterrole.yaml
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 7_mtv_serviceaccount.yaml
kubectl --kubeconfig=$KUBECONFIG_GREEN apply -f 6_mtv_clusterrole.yaml
kubectl --kubeconfig=$KUBECONFIG_GREEN apply -f 7_mtv_serviceaccount.yaml

# Extract tokens and CA certificates
kubectl --kubeconfig=$KUBECONFIG_BLUE get secret mtv-migration-sa-token -n openshift-mtv \
  -o jsonpath='{.data.token}' | base64 --decode > blue-token.txt

kubectl --kubeconfig=$KUBECONFIG_BLUE get cm kube-root-ca.crt -n openshift-mtv \
  -o jsonpath='{.data.ca\.crt}' > blue-ca.crt

kubectl --kubeconfig=$KUBECONFIG_GREEN get secret mtv-migration-sa-token -n openshift-mtv \
  -o jsonpath='{.data.token}' | base64 --decode > green-token.txt

kubectl --kubeconfig=$KUBECONFIG_GREEN get cm kube-root-ca.crt -n openshift-mtv \
  -o jsonpath='{.data.ca\.crt}' > green-ca.crt
```

**8_green_provider_secret.yaml** - Authentication Secret for Green Cluster
- Generated dynamically from token and CA cert
- Contains credentials for blue cluster to access green cluster
- Applied to blue cluster only

**Generate and apply:**
```bash
cat > 8_green_provider_secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: green-cluster-secret
  namespace: openshift-mtv
type: Opaque
stringData:
  token: "$(cat green-token.txt)"
  cacert: |
$(sed 's/^/    /' green-ca.crt)
EOF

kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 8_green_provider_secret.yaml
```

**10_green_provider.yaml** - Green Cluster Provider Definition
- References green-cluster API endpoint
- Uses secret for authentication
- Applied to blue cluster (where migration is initiated)
- **MUST wait for Status: Ready, Inventory: True before proceeding**

**11_host_provider.yaml** - Source Cluster Provider
- Automatically created by MTV as "host" provider
- Represents local blue cluster
- Verify it exists, no creation needed

**Commands:**
```bash
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 10_green_provider.yaml

# Wait for provider ready (may take 1-2 minutes)
kubectl --kubeconfig=$KUBECONFIG_BLUE get provider green-cluster -n openshift-mtv -w
# Wait for: Ready=True, Inventory=True

# Verify host provider exists
kubectl --kubeconfig=$KUBECONFIG_BLUE get provider host -n openshift-mtv
```

---

### PHASE 4: Network and Storage Mapping

**Critical Files to Create:**

**12_network_map.yaml** - Pod Network Mapping
- **CRITICAL PATTERN:** Use ONLY `type: pod` without name or namespace
- Reference pattern: `/Users/darjain/projects/openshift-gcp/cclm-env/network-map.yaml`
- Maps blue pod network → green pod network via Submariner tunnel
- Common mistake: Adding name/namespace causes "Source network not found" error

**Correct format:**
```yaml
map:
  - source:
      type: pod        # ONLY type field!
    destination:
      type: pod        # ONLY type field!
```

**13_storage_map.yaml** - Storage Class Mapping
- Maps source StorageClass → destination StorageClass
- **CRITICAL PATTERN:** Use `storageClass:` in destination (not `name:`)
- Reference pattern: `/Users/darjain/projects/openshift-gcp/cclm-env/storage-map.yaml`
- Both clusters use `standard-csi` StorageClass

**Correct format:**
```yaml
map:
  - source:
      name: standard-csi
    destination:
      storageClass: standard-csi    # NOT name!
      accessModes:
        - ReadWriteOnce
```

**Commands:**
```bash
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 12_network_map.yaml
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 13_storage_map.yaml

# Wait for Ready status
kubectl --kubeconfig=$KUBECONFIG_BLUE get networkmap blue-green-network-map -n openshift-mtv -w
kubectl --kubeconfig=$KUBECONFIG_BLUE get storagemap blue-green-storage-map -n openshift-mtv -w
```

**Validation:**
```bash
# Verify maps are valid
kubectl --kubeconfig=$KUBECONFIG_BLUE describe networkmap blue-green-network-map -n openshift-mtv
kubectl --kubeconfig=$KUBECONFIG_BLUE describe storagemap blue-green-storage-map -n openshift-mtv
# Should show: Status: Ready
```

---

### PHASE 5: VM Creation and Migration

**Critical Files to Create:**

**14_earth_vm.yaml** - Sample VM for Testing
- Minimal Fedora VM with 30Gi disk
- Uses container disk (quay.io/containerdisks/fedora:latest)
- Created on blue cluster (source)
- Instance type: u1.medium
- Network: pod network (masquerade)

**15_migration_plan.yaml** - Migration Plan Definition
- Defines VMs to migrate (earth-vm)
- References NetworkMap and StorageMap
- **CRITICAL:** Use `type: live` (not deprecated `warm: false`)
- Sets `preserveClusterCpuModel: true`, `preserveStaticIPs: false`
- Target namespace: `default`

**16_migration.yaml** - Migration Execution
- Triggers actual migration
- References migration plan
- Creates VMIM (VirtualMachineInstanceMigration) resource

**Commands:**
```bash
# Create VM on blue cluster
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 14_earth_vm.yaml

# Wait for VM running (may take 5-10 min for container disk pull)
kubectl --kubeconfig=$KUBECONFIG_BLUE get vm,vmi -n default -w
# Wait for: earth-vm Running=True, Ready=True

# Create and validate migration plan
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 15_migration_plan.yaml

# Wait for plan validation
kubectl --kubeconfig=$KUBECONFIG_BLUE get plan earth-vm-migration-plan -n openshift-mtv -w
# Wait for: Ready=True (validation passed)

# Execute migration
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 16_migration.yaml

# Monitor migration progress
kubectl --kubeconfig=$KUBECONFIG_BLUE get migration earth-vm-migration -n openshift-mtv -w
# Phases: Initialize → PrepareTarget → Synchronization → Completed
```

**Expected Timeline (from reference implementation):**
- Initialize: ~1 second
- PrepareTarget: ~10-15 seconds
- Synchronization: ~4-5 minutes (30Gi VM)
- **Total:** ~5 minutes

**Monitor in Detail:**
```bash
# Watch migration status
watch -n 5 "kubectl --kubeconfig=$KUBECONFIG_BLUE describe migration earth-vm-migration -n openshift-mtv | tail -30"

# Check VMIM on blue cluster
kubectl --kubeconfig=$KUBECONFIG_BLUE get vmim -A -w

# Monitor VM on green cluster
kubectl --kubeconfig=$KUBECONFIG_GREEN get vm,vmi -n default -w
```

---

### PHASE 6: Validation

**Post-Migration Checks:**

**On Blue Cluster (Source):**
```bash
# VM should be stopped after successful migration
kubectl --kubeconfig=$KUBECONFIG_BLUE get vm earth-vm -n default
# Expected: Running=False

# VMI should be deleted
kubectl --kubeconfig=$KUBECONFIG_BLUE get vmi earth-vm -n default
# Expected: Not found
```

**On Green Cluster (Destination):**
```bash
# VM should be running
kubectl --kubeconfig=$KUBECONFIG_GREEN get vm earth-vm -n default
# Expected: Running=True, Ready=True

# VMI should exist
kubectl --kubeconfig=$KUBECONFIG_GREEN get vmi earth-vm -n default -o wide

# PVC should be bound
kubectl --kubeconfig=$KUBECONFIG_GREEN get pvc -n default | grep earth-vm

# Test console access
virtctl console earth-vm -n default --kubeconfig=$KUBECONFIG_GREEN
```

**Network Connectivity Test:**
```bash
# Get VM IP on green cluster
VM_IP=$(kubectl --kubeconfig=$KUBECONFIG_GREEN get vmi earth-vm -n default -o jsonpath='{.status.interfaces[0].ipAddress}')

# Test connectivity from within green cluster
kubectl --kubeconfig=$KUBECONFIG_GREEN run test-pod --image=busybox --rm -it --restart=Never -- ping -c 3 $VM_IP
```

**Migration Success Verification:**
```bash
kubectl --kubeconfig=$KUBECONFIG_BLUE get migration earth-vm-migration -n openshift-mtv -o yaml | grep -A10 "status:"
# Should show: phase: Completed, succeeded: true
```

---

## Troubleshooting

### Issue 1: Network CIDR Overlap
**Symptom:** `subctl verify` fails with routing errors

**Solution:**
```bash
# Verify CIDRs
subctl show networks --kubeconfig $KUBECONFIG_BLUE
subctl show networks --kubeconfig $KUBECONFIG_GREEN

# If overlapping, rebuild green-cluster with different CIDRs
# See CRITICAL PREREQUISITE section above
```

### Issue 2: Provider Not Ready
**Symptom:** `kubectl get provider green-cluster` shows Ready=False

**Solution:**
```bash
# Check provider logs
kubectl --kubeconfig=$KUBECONFIG_BLUE logs -n openshift-mtv -l app=forklift-controller --tail=100

# Verify secret exists and is valid
kubectl --kubeconfig=$KUBECONFIG_BLUE get secret green-cluster-secret -n openshift-mtv -o yaml

# Test token manually
TOKEN=$(kubectl --kubeconfig=$KUBECONFIG_BLUE get secret green-cluster-secret -n openshift-mtv -o jsonpath='{.data.token}' | base64 --decode)
kubectl --token="$TOKEN" --server=https://api.green-cluster.cclm-chaos.aws.rhperfscale.org:6443 get nodes
```

### Issue 3: NetworkMap "Source network not found"
**Symptom:** `kubectl describe networkmap` shows error

**Solution:**
```bash
# Verify you used ONLY type: pod (no name or namespace)
kubectl --kubeconfig=$KUBECONFIG_BLUE get networkmap blue-green-network-map -n openshift-mtv -o yaml

# If incorrect, delete and recreate
kubectl --kubeconfig=$KUBECONFIG_BLUE delete networkmap blue-green-network-map -n openshift-mtv
kubectl --kubeconfig=$KUBECONFIG_BLUE apply -f 12_network_map.yaml
```

### Issue 4: Migration Stuck in Synchronization
**Symptom:** Migration remains in Synchronization phase > 10 minutes

**Solution:**
```bash
# Check Submariner connectivity
kubectl --kubeconfig=$KUBECONFIG_BLUE get pods -n submariner-operator
kubectl --kubeconfig=$KUBECONFIG_GREEN get pods -n submariner-operator

# Check VMIM logs
kubectl --kubeconfig=$KUBECONFIG_BLUE get vmim -A
kubectl --kubeconfig=$KUBECONFIG_BLUE logs -n openshift-cnv -l kubevirt.io=virt-handler --tail=100

# Verify cross-cluster routing
subctl show connections --kubeconfig $KUBECONFIG_BLUE
```

### Issue 5: Submariner Gateway Not Connecting
**Symptom:** `subctl show connections` shows "Not connected"

**Solution:**
```bash
# Check gateway pod logs
kubectl --kubeconfig=$KUBECONFIG_BLUE logs -n submariner-operator -l app=submariner-gateway --tail=100

# Verify gateway nodes are labeled
kubectl --kubeconfig=$KUBECONFIG_BLUE get nodes --show-labels | grep submariner
kubectl --kubeconfig=$KUBECONFIG_GREEN get nodes --show-labels | grep submariner

# Check endpoint status
kubectl --kubeconfig=$KUBECONFIG_BLUE get endpoints -A | grep submariner
```

---

## Critical Files Reference

**From Reference Implementation** (`/Users/darjain/projects/openshift-gcp/cclm-env/`):
- `mtv-migration-clusterrole.yaml` - Copy exactly for RBAC
- `network-map.yaml` - Pattern for pod network (type: pod only!)
- `storage-map.yaml` - Pattern for storage mapping (storageClass field)
- `earth-vm-migration-plan.yaml` - Migration plan template (type: live)
- `CROSS_CLUSTER_LIVE_MIGRATION_REPORT.md` - Complete reference documentation
- `QUICK_REFERENCE.md` - Command quick reference

**Cluster Kubeconfigs:**
- Blue: `blue-cluster/auth/kubeconfig`
- Green: `green-cluster/auth/kubeconfig`

---

## Success Criteria

- [ ] Both clusters have non-overlapping network CIDRs
- [ ] All operators installed and CSV in Succeeded state
- [ ] Feature gates enabled (decentralizedLiveMigration, feature_ocp_live_migration)
- [ ] Submariner connectivity verified (26/26 tests passing)
- [ ] Providers show Status: Ready, Inventory: True
- [ ] NetworkMap and StorageMap validated (Status: Ready)
- [ ] Migration plan validated (Ready=True)
- [ ] Migration completed in ~5 minutes (phase: Completed)
- [ ] VM running on green cluster
- [ ] VM stopped on blue cluster
- [ ] Network connectivity verified from VM

---

## Execution Summary

**One-Time Setup:** ~45-60 minutes
1. Install operators (15-20 min)
2. Deploy Submariner (10-15 min)
3. Configure MTV (10-15 min)
4. Create maps (5-10 min)

**Per-Migration:** ~5-10 minutes
1. Create VM (if needed)
2. Create migration plan
3. Execute migration
4. Validate

**Key Success Factors:**
- Non-overlapping CIDRs (absolute requirement)
- NetworkMap uses ONLY `type: pod`
- StorageMap uses `storageClass:` in destination
- Both feature gates enabled
- Provider Inventory=True before creating maps
- Migration type: `live` (not warm: false)