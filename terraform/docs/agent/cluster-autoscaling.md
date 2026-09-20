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
| the **storage** NIC | **the PVE template's own `net1`** — a clone keeps it, and Proxmox regenerates the MAC on every NIC (measured 2026-09-19), so two clones never share one |
| a node's address on the storage LAN | the island's own DHCP. Nothing per-node is declared anywhere — see "The storage network" below |

## The five requirements

**1. The PVE template must be right, or nothing downstream can be.**

- **CPU type `x86-64-v2-AES`** — Talos panics on `kvm64`.
- **A VLAN tag on the template's NIC.** The provider inherits it; an untagged template yields untagged
  nodes that can never reach the cluster.
- **One storage per template.** A cloud-init drive on a second storage gives
  `Multiple storage IDs found for template` and the NodeClass never becomes ready. The provider attaches
  its own CD-ROM for the join config, so a hand-built template does not need one.
- **A storage NIC on `net1`,** if the nodes are to reach the NAS: bridge `vmbr2` on balteus, jumbo MTU,
  **no VLAN tag** (the island is its own flat segment, deliberately unrouted). What matters is that both
  halves agree — a Karpenter clone inherits this `net1`, while a *static* node gets its second NIC from
  the cluster root's `storage_bridge`. Point them at different bridges and half the cluster lands on a
  segment the other half cannot see.
- **An image carrying the right extensions.** The module registers the schematic itself
  (`talos_image_factory_schematic` over `talos_schematic_extensions`), so the extension list *is* the
  definition of the node image: `iscsi-tools` for the block tier, `util-linux-tools` for the NFS one,
  `qemu-guest-agent` for everything. Nothing has to be kept in sync by hand — and "The storage network"
  below explains what registering it does and does not deliver.
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

## The storage network

The NAS sits on its own air-gapped segment — `192.168.88.0/24`, balteus' `vmbr2` over `bond0`, jumbo
frames — and the estate's rule is that every Kubernetes node gets a 10 Gbps link into it. Measured
2026-09-19 so nobody has to re-derive it:

| fact | how it was established |
|---|---|
| a clone **keeps** the template's `net1` (`vmbr2`, `mtu=9000`) | cloned template 9000 through the PVE API and read the result back |
| Proxmox **regenerates the MAC on every NIC** at clone time — `net0` *and* `net1` got new ones | the same clone. The provider sets only `queues` on each NIC, so this is Proxmox' behaviour, not the provider's |
| the island **runs DHCP**, so no `ipconfigN` is needed anywhere | owner-stated. Note what the alternative would have cost: the provider falls back to `ip=dhcp` for an interface with no `ipconfig`, and its IPAM pool form would have injected the *bridge* address as that interface's gateway — a second default route in the guest |
| the machine config asks **every** physical NIC for DHCP | `patch_network`'s selector is `physical = true`, so the storage NIC configures itself with nothing declared per node |

Three things follow — and they *are* the whole "add the storage network" job:

1. **The template.** `net1` → the storage bridge, MTU 9000, **no tag**. A burst node needs nothing else: it
   inherits the NIC with a MAC of its own. Template 9000 already has this.
2. **The static nodes.** The factory declares exactly one `network_device`, so a static node gets only
   `net0` and the template's `net1` never reaches it. `storage_bridge = "vmbr2"` in the cluster root adds
   it — verified inert while unset (`Plan: No changes`) — and it costs **one reboot per node**, because
   Talos enumerates interfaces at boot and will not see a NIC attached to a running VM.
3. **The image.** The extensions live in `talos_schematic_extensions` on the module, which registers the
   schematic and returns the ID (`talos_image_factory_schematic`) — so the list is the definition and
   nothing has to be kept in sync. That alone still does **not** deliver an extension, because the list
   decides what the *installer* image contains:
   - a **new** node installs from it, so it gets them;
   - a **clone** boots the template's already-installed disk and does **not** reinstall — the template has
     to be rebuilt from `factory.talos.dev/image/<schematic_id>/<version>/nocloud-amd64.raw.xz`, which is
     what the cluster root's `template_image_url` output prints;
   - an **existing** node keeps the system it installed until it is rolled (`talosctl upgrade`).

   Changing the extension list is otherwise a small, non-destructive diff: the provider re-registers the
   schematic and what reaches the nodes is the installer image inside an `UnattendedInstallConfig` patch
   carrying `wipe = false` and `reboot = false`, so no VM is replaced and nothing is wiped. On the first
   apply after this change the plan is `1 to add, 2 to change, 0 to destroy` — the schematic itself plus
   the two nodes' config applies — and the join config is re-rendered only because the ID is unknown until
   then.

   Rebuilding the template is `curl` + `qm importdisk` + `qm template`; the only written-up version of that
   is `spike/capmox-talos/runbook-2-talos-template.md`, and two of its rows are now wrong for this path —
   the class VLAN tag **does** belong on the template's `net0` (the provider inherits it, and the clone's
   `vlan_id` must agree), and the provider attaches its own cloud-init CD-ROM, so the template does not
   need one.

### A second Proxmox host (bukefalos)

The unmanaged template is looked up **by name, searched on every Proxmox node**, and the provider counts
only the zones that can see it. Adding a host therefore means the *same template name* must exist there —
same class VLAN tag on `net0`, **the same storage bridge on `net1`** (`vmbr2` has to exist on the new host
too, or clones arrive with a NIC attached to nothing), and the same `bootDevice.storage`.

That last one is the decision to make before the hardware arrives, because `bootDevice.storage` also
selects the zones and the template currently lives on `iscsi` — an LVM over a single iSCSI LUN, which
Proxmox reports as `shared=0`. Either

- present the same template and a same-named storage on the new host (local copies, per-host zones), or
- move the template and the clone disks to genuinely shared storage, which is what makes `zoneBalance`
  across hosts mean anything at all.

Everything else is ordinary Proxmox: join the host to the cluster, give it the storage bridge, and let the
pool place clones on it.

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
- **PSA is `restricted` in the dev cluster's `default` namespace.** A throwaway test pod needs a
  `securityContext` (no privilege escalation, drop ALL capabilities, `runAsNonRoot`, `RuntimeDefault`
  seccomp) or it is created with a violation warning — and would be rejected outright in a namespace that
  *enforces* rather than warns. Karpenter's own controllers are unaffected; this bites test workloads only.
- **Pin the vault's snapshots and the template's versions together** if a restore target exists: a snapshot
  from a newer instance will not load into an older one.
