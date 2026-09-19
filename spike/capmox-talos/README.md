# Spike — Talos on Proxmox VMs via CAPMOX, driven by a k3s management cluster

**Status: spike.** Timeboxed, throwaway, and it ends with either a measurement or a decision — not with a
cluster anything depends on. What graduates from here belongs in `bootstrap/` and `devops/argocd/`, not in
this directory.

## The question this exists for

The estate's cluster strategy has one open question that blocks everything downstream of it: **how do we
provision the nodes that are VMs, and can one management plane drive the physical ones too?** Today
everything is Sidero Metal — one `Server` per machine, VMs included, PXE-booted — on a provider that is
unmaintained upstream, with the CAPI specs sitting on `v1alpha2`/`v1alpha3` CRDs.

This tests the alternative: **k3s on balteus** running CAPI with **CAPMOX**
(`cluster-api-provider-proxmox`), provisioning a Talos cluster out of **Proxmox VMs, tagged into `srv`**.

## Two hypotheses — both must come back answered

**H1 — the bootstrap channel.** CAPMOX delivers bootstrap data through a cloud-init drive; Talos' `nocloud`
platform reads NoCloud `user-data` as its machine config. So a Talos *nocloud* image plus CAPMOX should
produce a joining node. It is **not documented and there is no Talos flavor in CAPMOX** — but it is in use:
[#392 "[Talos] control-plane VM never created"](https://github.com/ionos-cloud/cluster-api-provider-proxmox/issues/392)
and [#342 "[Talos] Wrong providerID"](https://github.com/ionos-cloud/cluster-api-provider-proxmox/issues/342)
are both Talos reports, both closed. #342 also gives a *reported-working* version set — CAPI v1.7.2,
`talos-boot` v0.6.5, `talos-cp` v0.5.6, `ipam-in-cluster` v0.1.0 — worth falling back to if current
versions misbehave.

**H2 — who owns a node's address.** CAPMOX's IPAM deliberately works *without* DHCP
(`cluster-api-ipam-provider-in-cluster`); the estate's doctrine is the opposite — the reservation owns the
address and the name follows it. Which one wins here decides whether cluster nodes keep reservations and
names, or move to a CAPMOX-owned pool. Relevant: CAPMOX's cloud-init network-config support in *nocloud*
format is still an open issue
([#51](https://github.com/ionos-cloud/cluster-api-provider-proxmox/issues/51)), so the static-address path
may simply not exist yet — in which case Talos takes a DHCP lease and the router's reservation stays the
owner. **Either answer is a result; write down which one you got, with the evidence.**

## Explicitly out of scope

Storage (Longhorn/NFS), ingress/reverse proxy, the autoscaler deployment, and the metal half of the estate.
The autoscaler is excluded on purpose: this spike measures *provisioning* time by hand (scale a
MachineDeployment 0→1), which is exactly the number the autoscaler decision needs. Deploying it is a
separate PR, and it belongs in `devops/argocd/` — nothing in this repo deploys it today even though the GPU
pool already carries its annotations.

## What it has to produce

| measurement | why |
|---|---|
| CP + worker VM created, Talos joined, node `Ready` | H1 answered |
| where the node's address came from — CAPMOX pool or DHCP lease | H2 answered |
| seconds from `replicas: 1` to `Node Ready` | the lead time a VM pool gives the autoscaler |
| a delete leaves no orphan VM in Proxmox | teardown as a property, not a cleanup |

## Decisions it feeds

1. **Management plane:** k3s on balteus running CAPI for both media — yes/no.
2. **VM pools:** CAPMOX — yes/no; and if yes, who owns their addresses.
3. **Metal pools:** keep Sidero for the boxes it already drives, or move to Metal3/Tinkerbell.
4. **When to rewrite** `bootstrap/`'s specs onto maintained CRDs.

## Runbooks, in order

| # | file | who |
|---|---|---|
| 1 | `runbook-1-k3s.md` | you — provision the k3s VM in `srv` (the agent has no access to balteus) |
| 2 | `runbook-2-talos-template.md` | you — build the Talos *nocloud* Proxmox template |
| 3 | `runbook-3-cluster.md` | you — install providers, apply, answer H1/H2, measure |
| 4 | `runbook-4-teardown.md` | you — end the spike cleanly |

## Repo artifacts in this PR

- `spike/capmox-talos/**` — the runbooks and two manifests.
- `terraform/routeros/dns.tf` — one record, `adonai.srv.hnatekmar.dev`, so the management VM has a name and
  nothing references it by address. **Merging this applies it** (the router apply runs on merge, on the mgmt
  runner).

## Result, 2026-09-16 — H1 is a clear **no** on released, modern components

The cluster objects reconciled; the machines never did. Precisely, in the order it happened:

- `proxmoxcluster/spike` → **`READY=true`**, endpoint `172.16.40.160:6443`; `cluster/spike` →
  **Provisioned**, **InfrastructureReady**; the `TalosControlPlane` and both `Machine`s were created.
- CAPMOX then sat on **`"Bootstrap data secret reference is not yet available"`** and never cloned a VM —
  its log has **zero** clone/task lines, so nothing was orphaned in Proxmox.
- The Talos bootstrap provider sat on **`"Waiting for OwnerRef on the talosconfig"`**: the `TalosConfig`
  objects existed but carried no owner reference, and the provider refuses to render a machine config
  without one (`bsutil.GetConfigOwner` returns nil).
- That ownerRef is CAPI's Machine controller to set. Which is the finding: **the released Talos providers
  are built against an older CAPI than CAPMOX's modern line requires.**

| component | version | declared / built against |
|---|---|---|
| cluster-api (core) | `v1.12.11` | — |
| infrastructure-proxmox | `v0.9.1` | CAPMOX's matrix: **CAPI v1.11 / v1.12** |
| bootstrap-talos (cabpt) | `v0.6.12` | `go.mod`: **cluster-api v1.10.9** |
| control-plane-talos | `v0.5.13` | same line, same date (2026-04-27) |
| cabpt `main` (unreleased) | — | `go.mod`: cluster-api **v1.12.2** |
| cabpt prerelease | `v0.7.0-alpha.2` | the only published artefact on the newer line |

**So the intersection is empty on released, modern components.** The four ways forward:

1. **CAPI v1.10.x + CAPMOX v0.7.x** — every declared support satisfied, but CAPMOX v0.7 is the *obsolete*
   `v1alpha1` line (core `v1beta1`), so the manifests here would have to be rewritten down to obsolete APIs.
2. **CAPI v1.12.x + CAPMOX v0.9.x + cabpt `v0.7.0-alpha.2`** — modern APIs, on an **alpha** Talos provider.
   (This is the cheap experiment that would settle "wait for cabpt v0.7 or abandon": re-init with the alpha
   and re-apply; ten minutes.)
3. **Give up the pairing for VMs**: CAPMOX's documented **kubeadm** flavours for VM pools, Talos kept for bare
   metal (Sidero as today, or Metal3/Tinkerbell).
4. **Drop CAPMOX**: provision Talos VMs another way (Terraform on Proxmox — declarative but episodic, no
   reconciler).

**H2 was never reached**, and that is a consequence rather than a failure: with no VM cloned there was no
machine to take an address from, so "does CAPMOX's IPAM own cluster addressing, or the router's
reservation" stays open until H1 has a home.

### What the attempt established anyway

- CAPMOX's validation is real and specific: `ProxmoxCluster.spec.ipv4Config` **may not contain the endpoint
  IP**, which is why the control plane gets a one-address pool of its own. And against balteus' *compat*
  address with a token secret, the `ProxmoxCluster` reached `READY=true` — so credentials, endpoint,
  `vlan` tagging and the provider's health path are all sound.
- Three manifest surprises, all from the *installed* CRDs versus the estate's older specs:
  `TalosControlPlane.spec.controlPlaneConfig` wants `generateType`/`talosVersion` **inside `controlplane`**;
  `infrastructureTemplate` takes `apiVersion`, not `apiGroup`; and `TalosConfigTemplate.template.spec`
  advertises only `data`/`generateType` while accepting and storing `talosVersion`/`configPatches` — which
  should be distrusted until a join config actually renders.
- The version discipline earned its keep: because core was pinned *inside* CAPMOX's declared range, this
  failure is attributable to the provider pairing rather than to an untested version combination.
