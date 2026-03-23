# Zero-Downtime VM Migration Across OpenShift Clusters: A Practical Guide

*How we migrated a running VM from one OpenShift cluster to another in under 5 minutes with zero downtime.*

---

## TL;DR

We migrated a running VM from one OpenShift cluster to another in under 5 minutes with zero downtime, using MTV/Forklift for orchestration and Submariner for cross-cluster networking. This article walks through the complete setup, the problems we hit, and how we solved them.

---

## The Problem

Imagine this: you need to drain an entire OpenShift cluster for a major upgrade, but you have stateful VMs running on it that can't afford downtime. Or you want to rebalance workloads across clusters during peak traffic. Or you need disaster recovery that doesn't mean "restart everything from scratch."

In-cluster live migration -- moving a VM between nodes within the same cluster -- has been available in OpenShift Virtualization for a while. But what about moving a running VM from one cluster to a completely different cluster?

That's **cross-cluster live migration** (CCLM), and as of OpenShift 4.21, it's possible using a combination of three technologies.

---

## The Solution Stack

| Component | Role |
|-----------|------|
| **OpenShift Virtualization (CNV)** | Runs VMs on OpenShift via KubeVirt |
| **Migration Toolkit for Virtualization (MTV/Forklift)** | Orchestrates the migration lifecycle |
| **Submariner** | Creates an encrypted IPsec tunnel between clusters |

### How It Works

MTV creates a migration plan that specifies which VMs to move and where. Submariner provides the encrypted network path between clusters. During migration, the VM's memory pages stream across the Submariner tunnel while the VM continues running on the source cluster. The cutover -- where the VM stops on the source and starts on the target -- is nearly instantaneous.

```
BLUE CLUSTER (Source)                   GREEN CLUSTER (Target)
+--------------------------+            +--------------------------+
| Pod: 10.128.0.0/14      |            | Pod: 10.224.0.0/14       |
| Svc: 172.30.0.0/16      |<==IPsec==> | Svc: 172.24.0.0/16       |
| [earth-vm] running       |   Tunnel   | [earth-vm] <-- landed    |
| Submariner Gateway       |            | Submariner Gateway       |
+--------------------------+            +--------------------------+
```

---

## Our Environment

We used two freshly installed OpenShift clusters on GCP, both in the same region:

| | Blue Cluster (Source) | Green Cluster (Target) |
|---|---|---|
| **OpenShift** | 4.21.2 | 4.21.2 |
| **CNV** | 4.21.1 | 4.21.1 |
| **MTV** | 2.11.1 | 2.11.1 |
| **Submariner** | 0.23.1 | 0.23.1 |
| **Network Plugin** | OVNKubernetes | OVNKubernetes |
| **Region** | GCP us-central1 | GCP us-central1 |
| **Topology** | 3 masters + 3 workers | 3 masters + 3 workers |
| **Pod CIDR** | 10.128.0.0/14 | 10.224.0.0/14 |
| **Service CIDR** | 172.30.0.0/16 | 172.24.0.0/16 |
| **Machine CIDR** | 10.0.0.0/16 | 10.2.0.0/16 |

One thing we got right from the start: **non-overlapping CIDRs**. This turned out to be the most critical prerequisite.

---

## The Walkthrough

### Phase 1: Operator Installation (~15 minutes)

We installed two operators on **both** clusters from OperatorHub:

- **OpenShift Virtualization** (channel: `stable`)
- **Migration Toolkit for Virtualization** (channel: `release-v2.11`)

After the CSVs reached `Succeeded`, we created the HyperConverged CR for CNV. MTV auto-creates its ForkliftController CR.

The step most guides skip: **two feature gates must be enabled on both clusters** for cross-cluster live migration to work:

```bash
# CNV: Enable decentralized live migration
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  --type json \
  -p '[{"op":"replace","path":"/spec/featureGates/decentralizedLiveMigration","value":true}]'

# MTV: Enable OCP live migration
oc patch ForkliftController forklift-controller -n openshift-mtv \
  --type json \
  -p '[{"op":"add","path":"/spec/feature_ocp_live_migration","value":"true"}]'
```

After patching the HyperConverged CR, `virt-synchronization-controller` pods automatically start in the `openshift-cnv` namespace. These pods coordinate the cross-cluster handshake during migration. We waited until both pods showed `Running` before proceeding.

### Phase 2: Submariner Deployment (~10 minutes)

Submariner creates an encrypted IPsec tunnel between clusters. The nice thing is you don't install it from OperatorHub -- the `subctl` CLI handles everything:

```bash
# Deploy broker on blue cluster
subctl deploy-broker --kubeconfig $KUBECONFIG_BLUE

# Label one worker per cluster as gateway
KUBECONFIG=$KUBECONFIG_BLUE oc label node \
  $(oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].metadata.name}') \
  submariner.io/gateway=true

# Join both clusters
subctl join broker-info.subm --kubeconfig $KUBECONFIG_BLUE \
  --clusterid blue-cluster --cable-driver libreswan
subctl join broker-info.subm --kubeconfig $KUBECONFIG_GREEN \
  --clusterid green-cluster --cable-driver libreswan
```

The `subctl join` command installs the Submariner operator, creates the gateway pods, and establishes the IPsec tunnel automatically.

Once connected, we verified with `subctl show connections`:

```
GATEWAY                  CLUSTER         REMOTE IP    CABLE DRIVER   STATUS      RTT avg.
green-cluster-worker-a   green-cluster   10.0.128.2   libreswan      connected   485.835us
```

RTT under 500 microseconds. Same-region GCP networking at its best.

### Phase 3: MTV Cross-Cluster Configuration (~10 minutes)

This phase wires up authentication so the source cluster (blue) can reach the target cluster's (green) API server.

We created:
1. A **ClusterRole** (`live-migration-role`) with permissions for VMs, DataVolumes, PVCs, StorageClasses, and other migration-related resources -- applied to **both** clusters
2. A **ServiceAccount** (`mtv-migration-sa`) with a long-lived token secret -- on **both** clusters
3. A **Provider Secret** containing green's SA token and CA certificate -- on **blue only**
4. A **Provider CR** pointing to green's API endpoint -- on **blue only**

The `host` provider (representing blue, the local cluster) is auto-created by MTV. Once both providers showed `Ready=True, Inventory=True`, we knew the clusters could talk to each other through MTV.

### Phase 4: Network and Storage Mapping (~5 minutes)

Network and storage maps tell MTV how to translate resources between clusters.

**NetworkMap**: Maps the pod network on blue to the pod network on green. The mapping is straightforward since both clusters use the default pod network -- but the syntax is critical:

```yaml
map:
  - source:
      type: pod        # ONLY type field -- no name or namespace
    destination:
      type: pod        # ONLY type field -- no name or namespace
```

**StorageMap**: Maps `standard-csi` StorageClass on blue to `standard-csi` on green:

```yaml
map:
  - source:
      name: standard-csi
    destination:
      storageClass: standard-csi    # Must be storageClass, NOT name
      accessModes:
        - ReadWriteOnce
```

Both maps showed `Ready=True` within seconds of applying.

### Phase 5: The Migration (~5 minutes)

With everything in place, we triggered the migration through the OpenShift Console:

1. Opened the console on blue-cluster
2. Navigated to **Migration for Virtualization** > **Create Migration Plan**
3. Selected `host` as source and `green-cluster` as target
4. Picked our test VM (`earth-vm`)
5. Selected the existing network and storage maps
6. Chose **Live migration**
7. Hit Start

The migration progressed through three stages:

| Stage | Duration | What Happens |
|-------|----------|-------------|
| Initialize | ~1 second | Plan validation, resource checks |
| PrepareTarget | ~15 seconds | Creates PVCs, sets up networking on green |
| Synchronization | ~4 minutes | Memory pages stream over the Submariner tunnel |

**Total: 5 minutes and 5 seconds.** The VM was running on green-cluster without ever being shut down.

---

## The Results

On blue-cluster (source), the VM was stopped:

```
$ oc get vm earth-vm -n default
NAME       AGE   STATUS    READY
earth-vm   30m   Stopped   False
```

On green-cluster (target), the VM was running:

```
$ oc get vm earth-vm -n default
NAME       AGE   STATUS    READY
earth-vm   2m    Running   True
```

The PVC was bound, the VM was accessible via console, and network connectivity worked from within the green cluster. A complete, seamless migration.

---

## Lessons Learned

### 1. CIDR Overlap Is a Hard Blocker

Our initial test environment had both clusters using OpenShift's default CIDRs (10.128.0.0/14 for pods, 172.30.0.0/16 for services). Submariner detected the overlap and refused to route traffic. We had to rebuild one cluster with different CIDRs.

**Lesson:** Plan your CIDRs before cluster creation. If you know you'll do cross-cluster networking, use non-overlapping ranges from day one.

### 2. Cloud Networking Isn't Automatic

On GCP, each OpenShift cluster creates its own VPC network. Our Submariner gateway pods couldn't reach each other -- the logs showed a misleading `sendmsg: operation not permitted` error that actually meant "packets can't leave this VPC."

The fix required two things:
- **VPC Peering** between the two cluster networks
- **Firewall rules** allowing UDP 500 (IKE), UDP 4500 (NAT-T), UDP 4800 (VXLAN), and ESP protocol 50 (IPsec)

**Lesson:** Check cloud networking before blaming Submariner. The tunnel can't work if the underlying network doesn't allow the traffic.

### 3. NetworkMap: Less Is More

We spent an hour debugging a "Source network not found" error on our NetworkMap. The cause? We'd added `name: pod` and `namespace: default` to the source field. For pod networks, the NetworkMap requires ONLY the `type: pod` field -- any additional fields cause validation failures.

**Lesson:** For pod network mappings, use exactly `type: pod` and nothing else.

### 4. StorageMap Field Names Matter

The StorageMap destination requires `storageClass:` as the field name. Using `name:` (which seems intuitive) causes a cryptic "Source storage: either ID or Name required" error.

**Lesson:** YAML field names in Forklift CRDs aren't always intuitive. Check the API reference or use a working example.

### 5. Feature Gates Are Easy to Forget

Without both `decentralizedLiveMigration` (on HyperConverged) and `feature_ocp_live_migration` (on ForkliftController) enabled on **both** clusters, the live migration option simply doesn't appear. There's no clear error message -- it just looks like the feature doesn't exist.

**Lesson:** Enable feature gates on both clusters and verify with `oc get` before proceeding. Check for the `virt-synchronization-controller` pods as confirmation.

---

## When to Use Cross-Cluster Live Migration

| Use Case | Good Fit? |
|----------|-----------|
| Cluster upgrades with zero VM downtime | Yes |
| Disaster recovery / cluster failover | Yes |
| Workload rebalancing across clusters | Yes |
| Dev-to-prod VM promotion | Maybe (consider CI/CD instead) |
| Large-scale datacenter migration | Yes, but plan for bandwidth |

### When NOT to Use It

- **Overlapping CIDRs**: Fix the network ranges first. There's no workaround (Globalnet adds too much complexity).
- **No network path**: Submariner needs reachability between gateway nodes. Air-gapped clusters won't work.
- **Host-specific hardware**: VMs with GPU passthrough or SR-IOV dependencies are tied to specific hardware.

---

## Quick Reference Card

### Required Operators (install on both clusters)

| Operator | Channel | Namespace |
|----------|---------|-----------|
| OpenShift Virtualization | `stable` | `openshift-cnv` |
| Migration Toolkit for Virtualization | `release-v2.11` | `openshift-mtv` |

### Feature Gates (enable on both clusters)

| Gate | Component | Value |
|------|-----------|-------|
| `decentralizedLiveMigration` | HyperConverged CR | `true` |
| `feature_ocp_live_migration` | ForkliftController CR | `"true"` |

### Submariner Ports (open on cloud firewall)

| Port | Protocol | Purpose |
|------|----------|---------|
| 500 | UDP | IKE key exchange |
| 4500 | UDP | NAT-T traversal |
| 4800 | UDP | VXLAN encapsulation |
| 50 | ESP | IPsec encrypted data |

### Common Errors and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| "Source network not found" | Added `name`/`namespace` to NetworkMap | Use only `type: pod` |
| "Source storage: either ID or Name required" | Used `name:` in StorageMap destination | Use `storageClass:` instead |
| Gateway stuck in "connecting" | Firewall or VPC blocking | Add VPC peering + firewall rules |
| Provider not Ready | Invalid token or wrong CA cert | Regenerate SA token and extract fresh CA |
| Migration stuck in Synchronization | Submariner tunnel issue | Check `oc get pods -n submariner-operator` |

---

## Timeline Summary

| Phase | Duration | What Gets Done |
|-------|----------|---------------|
| 1. Operators + Feature Gates | ~15 min | CNV, MTV installed and configured |
| 2. Submariner | ~10 min | IPsec tunnel established |
| 3. MTV Configuration | ~10 min | RBAC, providers, authentication |
| 4. Network + Storage Maps | ~5 min | Resource mapping between clusters |
| 5. Migration | ~5 min | VM migrated live |
| **Total Setup** | **~45 min** | One-time setup |
| **Per Migration** | **~5 min** | Each subsequent VM migration |

---

## What's Next

Cross-cluster live migration on OpenShift is currently a **Technology Preview** feature. As it matures, expect:
- Simplified setup with fewer manual steps
- Better integration with RHACM (Red Hat Advanced Cluster Management)
- Support for more complex networking topologies
- Performance optimizations for larger VMs and higher dirty-page rates

For now, it works, it's fast, and it opens up use cases that simply weren't possible before.

---

## Resources

- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [MTV Documentation](https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/)
- [Submariner Documentation](https://submariner.io/getting-started/)
- [Source Code and Manifests](https://github.com/<your-username>/mtv-submariner-live-migration)

---

*Tested on OpenShift 4.21.2 with CNV 4.21.1, MTV 2.11.1, and Submariner 0.23.1 on GCP (us-central1). March 2026.*
