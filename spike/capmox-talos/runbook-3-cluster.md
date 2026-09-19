# Runbook 3 — providers, the cluster, and the two answers

Everything below runs on the k3s VM from runbook 1, except the Proxmox-side commands.

## 1. Install CAPI and the providers

```bash
# Pin everything. CAPMOX v0.9 tracks CAPI v1.11–v1.12 (its own support matrix).
# Fallback if the pairing misbehaves: CAPI v1.7.2 + talos-boot v0.6.5 + talos-cp v0.5.6 +
# ipam-in-cluster v0.1.0 — the set reported working in CAPMOX issue #342.
export CAPI_VERSION=v1.11.5
export CAPMOX_VERSION=v0.9.0

clusterctl init \
  --core cluster-api:$CAPI_VERSION \
  --bootstrap talos \
  --control-plane talos \
  --infrastructure proxmox:$CAPMOX_VERSION \
  --ipam in-cluster
```

Verify:

```bash
kubectl -n capmox-system get pods          # Running
kubectl -n cabpt-system get pods           # Running  (talos bootstrap provider)
kubectl get crd | grep -E 'proxmox|ipam'   # ProxmoxCluster/ProxmoxMachine/…, GlobalInClusterIPPool
```

**Optional coexistence check** — the claim that one management cluster can drive both media:

```bash
clusterctl init --infrastructure sidero
kubectl get pods -A | grep -E 'sidero|capmox'   # both healthy, side by side
```

That is worth doing even though this spike provisions nothing through Sidero: it is the evidence for
retiring the old Matchbox/Sidero bootstrap cluster. Sidero's controller wants its own environment variables
(`SIDERO_CONTROLLER_MANAGER_API_ENDPOINT`, `…_SIDEROLINK_ENDPOINT`) — see
`bootstrap/argocd/devops/initialize_sidero_metal.sh` for the values in use today.

## 2. Proxmox credentials — out of band, never in the repo

On the Proxmox side (least privilege is documented in CAPMOX's `advanced-setups.md`):

```bash
pveum user add capmox@pve
pveum aclmod / -user capmox@pve -role PVEVMAdmin
pveum user token add capmox@pve capi -privsep 0
```

Then the Secret CAPMOX reads through `ProxmoxCluster.spec.credentialsRef` (keys: `url`, `token`, `secret`;
label `platform.ionos.com/secret-type=proxmox-credentials`):

```bash
kubectl create secret generic spike-proxmox-credentials \
  --from-literal=url=https://<proxmox-host>:8006 \
  --from-literal=token='capmox@pve!capi' \
  --from-literal=secret='<token-secret>'
kubectl label secret spike-proxmox-credentials platform.ionos.com/secret-type=proxmox-credentials
```

**A re-create needs this secret re-created first.** Measured 2026-09-16: deleting the spike `Cluster` (and
with it the `ProxmoxCluster`) took `spike-proxmox-credentials` with it. The CAPI-generated secrets going is
expected (`spike-ca`, `spike-kubeconfig`, `spike-talos` — all gone, correctly), but this one is *created by
hand* and it went too. The next apply then fails in a way that points at the wrong layer entirely:

```
Unable to initialize ProxmoxClient
  github.com/ionos-cloud/cluster-api-provider-proxmox/pkg/scope.NewClusterScope
```

— and nothing else: no `ProxmoxCluster` provisioning, therefore **no Machines at all**, which reads as a
bootstrap or provider problem and is a missing secret. The `GlobalInClusterIPPool`s and the
`*MachineTemplate`s are standalone and survive a cluster deletion, so those do not need re-creating.

If the token's secret value was only ever displayed once and is not written down, mint a fresh one on balteus
(`pveum user token add capmox@pve capi -privsep 0`) — the *token id* alone is not enough to rebuild this.

## 3. Apply, and correct the placeholders

```bash
kubectl apply -f manifests/ipam-pool.yaml
kubectl apply -f manifests/cluster-talos-proxmox.yaml
```

Values in the manifests that are placeholders until you set them: `sourceNode` (the Proxmox node name),
`templateID` (9000 from runbook 2), disk size/storage, the installer image's schematic + Talos version, and
the Kubernetes `version` on the MachineDeployment (it must be a version your pinned Talos supports).

## 4. H1 — does the bootstrap channel work?

```bash
kubectl get cluster,machine,proxmoxmachine -A -w
kubectl -n default describe proxmoxmachine spike-cp-xxxxx     # conditions and events carry the reason
```

**Known Talos symptoms** (both were real, both closed — check these before blaming the network):

- **The control-plane VM is never created and Proxmox logs no API task at all.** That is issue #392's shape:
  a provider/Talos-template interaction. Re-check `templateID` / `sourceNode` / the cloud-init drive on the
  template, and the shape of the Talos bootstrap data — not the VLAN.
- **The node joins but its `providerID` reads `talos://nocloud/<ip>`** instead of `proxmox://<id>` (#342).
  Cosmetic here; a workload cluster that needs it runs `talos-ccm`.

Answer to record: **did a Talos CP VM clone, boot and join, and how long did it take?**

## 5. H2 — who owns the node address?

```bash
kubectl -n default get proxmoxmachine \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses}{"\n"}{end}'

# on the router — did the *router* hand it a lease?
/ip dhcp-server lease print where address~"172.16.40.1"
```

- Machine holds an address from the **IPAM pool** (`.160–.175`) and Talos honours it → **CAPMOX owns
  addressing**. Consequence: for cluster nodes the estate's "reservation owns the address" doctrine changes,
  and DNS keeps one name per cluster (the control-plane endpoint) rather than per-node names.
- Machine only comes up on a **DHCP lease** → CAPMOX's nocloud network-config support (#51) is not there yet.
  The router's reservation stays the owner, and the spike's IPAM pool is unused. That is a legitimate,
  decision-shaped result.

## 6. Measure provisioning time — the number the autoscaler needs

```bash
kubectl -n default scale machinedeployment spike-workers --replicas=0
# wait until the VM is gone in Proxmox:  qm list | grep spike

time kubectl -n default scale machinedeployment spike-workers --replicas=1
# then watch:  kubectl get machines,nodes -w
```

Record three times: **scale → VM appears in Proxmox**, **→ node registers**, **→ `Ready`**. The sum is the
lead time a VM-backed pool gives the cluster autoscaler (`--max-node-provision-time` default is 15m, so
anything near that needs the flag raised). Compare it with a metal pool's provisioning cycle — that
comparison is what decides which pools are allowed to autoscale and which get a fixed floor.
