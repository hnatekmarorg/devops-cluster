# Cluster autoscaling idiom (Karpenter + Proxmox CCM)

How a cluster gets elastic VMs, and the five things that must be true for it to work. Every one of these
cost time to find; none of them is obvious from either project's docs.

## The shape

```
NodePool  ──▶  ProxmoxNodeClass  ──▶  ProxmoxUnmanagedTemplate  ──▶  a PVE template you build
(what)          (where/how)            (which template)               (the hardware facts)
```

A `NodePool` never names a VM, a size or a Proxmox node. It names a **NodeClass**, which names a
**template**. The pool picks an **instance type** — the provider's own grid, `<family>.<N>VCPU-<R>GB` with
families `c1` (1:2), `t1` (1:3), `s1` (1:4), `m1` (1:8), `x1` (1:16) and N ∈ {1,2,4,8,16} — and that *is*
the node size: `m1.4VCPU-32GB` becomes a 4-core, 32 GiB VM. The digit in the family name is a generation
marker, not arithmetic.

## Where every property of the resulting VM comes from

| VM property | decided by |
|---|---|
| cores / memory | the instance type the pool picks |
| disk size + storage | `nodeClass.bootDevice` |
| which template is cloned | `instanceTemplateRef` → the template CR's `templateName` (searched by name on every PVE node) |
| VLAN tag / bridge / NIC model | **the PVE template's own `net0`** — the provider builds a fresh net0 (new MAC, `queues=2`) but keeps the tag |
| CPU type | the instance type (provider default `x86-64-v2-AES`) |
| machine config (hostname, network, join token) | `metadataOptions.templatesRef` → a Secret, delivered as a cloud-init CD-ROM |
| address | DHCP from the router — burst nodes take pool leases, no reservations |

## The five requirements

**1. The PVE template must be right, or nothing downstream can be.**

- **CPU type `x86-64-v2-AES`** — Talos panics on `kvm64`.
- **A VLAN tag on the template's NIC.** The provider inherits it; an untagged template yields untagged
  nodes that can never reach the cluster.
- **One storage per template.** A cloud-init drive on a second storage gives
  `Multiple storage IDs found for template` and the NodeClass never becomes ready. The provider attaches
  its own CD-ROM for the join config, so a hand-built template does not need one.
- **Sized generously enough for the instance types you will offer.**

**2. `bootDevice.storage` selects the zones.** The provider derives zones from the storage named there and
counts only zones that can see the template. The wrong storage yields `TemplatesNotFound`, which *reads*
like a template-name problem and is not one.

**3. The join config must declare its network.** On the `nocloud` platform Talos does **not** assume DHCP:
with no `machine.network.interfaces`, the guest boots with no address at all and every log line says
`network is unreachable` — no DNS, no NTP, no join — while looking superficially healthy from the host
side. This is invisible in any manifest and was the single hardest thing to find:

```yaml
machine:
  network:
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: true
```

**4. `--cloud-provider=external` on every kubelet, and the CCM running.** Without both, Karpenter's
provider never learns a node's `providerID`, because nothing populates it. The consequences look
unrelated:

- the NodeClaim never leaves `Unknown`, so Karpenter times out, **terminates the instance** and provisions
  again — a churn loop that quietly consumes VMIDs and disk;
- `karpenter.sh/nodepool` is never applied to the node, so pool-targeted pods never schedule even though
  the node is Ready and empty;
- nodes whose VMs are gone linger as `NotReady` because nothing removes them.

The CCM's own errors name the requirement precisely (`node does not have --cloud-provider=external
argument`), so read its logs before theorising.

**On Talos the flag goes in the `KubeletConfig` document, patched by kind.** The machine config is
multi-document, which rules out JSON patches (`JSON6902 patches are not supported for multi-document
machine configuration`), and patching the legacy `machine.kubelet` block collides
(`kubelet config is already set in v1alpha1 config`). What works:

```bash
cat > /tmp/kc-patch.yaml <<'EOF'
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  cloud-provider: external
EOF
talosctl --talosconfig ./talosconfig -e <cp-ip> -n <node-ip> \
  patch machineconfig --patch @/tmp/kc-patch.yaml
```

Confirm `provided-node-ip` appears on the node, then the CCM will populate `providerID` on its next cycle
(restart its pod to force one).

**5. The scope of the API token.** The provider needs `VM.Config.*`, `Datastore.*` and `VM.PowerMgmt`; the
CCM needs only `VM.Audit`, `Sys.Audit`, `VM.GuestAgent.Audit`. Give each its own token — the CCM's config
is the same shape as the provider's, so pointing the CCM chart at the provider's Secret works for a
proof of concept but couples two privileges that should be separate.

## What "working" looks like

```
pending pod → instance type chosen → VM cloned → node joins → Ready → pod placed
                                                                      ↓ workload deleted
                                              consolidation → node removed → VM deleted
```

Measured on the dev cluster: **≈3 minutes** from clearing a claim to a Ready node, with a 2 vCPU / 4 GiB
instance type.

## Installing the two controllers

```bash
# Karpenter provider (also what creates VM clones)
helm upgrade --install karpenter oci://ghcr.io/sergelogvinov/charts/karpenter-provider-proxmox \
  -n kube-system --set existingConfigSecret=<proxmox-credentials-secret>

# Proxmox CCM — notes: needs --cloud-provider=external on every kubelet (see above)
helm upgrade --install proxmox-ccm oci://ghcr.io/sergelogvinov/charts/proxmox-cloud-controller-manager \
  -n kube-system \
  --set existingConfigSecret=<proxmox-credentials-secret> \
  --set existingConfigSecretKey=config.yaml \
  --set 'enabledControllers[0]=cloud-node' \
  --set 'enabledControllers[1]=cloud-node-lifecycle'
```

## Operational notes

- **Force a reconcile after config changes** by restarting the controller pod; both CCM and provider work
  on multi-minute cycles and a stale log can look like a fresh failure.
- **Verify Proxmox deletions with tasks, not immediate listings** — deletes are async tasks, and
  `/cluster/resources?type=vm` is the only listing that works (`type=qemu` returns nothing, silently,
  which once made nine orphaned VMs look like a clean estate).
- **Orphans happen when claims are force-deleted while a provider is unhealthy.** It stops the VMs and
  never removes them. For a leak detector, alert on a VM whose ID is beyond the pool's base VMID with no
  live NodeClaim naming it.
- **Pin the vault's snapshots and the template's versions together** if a restore target exists: a snapshot
  from a newer instance will not load into an older one.
