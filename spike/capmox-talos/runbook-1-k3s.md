# Runbook 1 — the k3s management VM in `srv`

Runs on balteus / Proxmox. Yours to execute: the agent has no access to balteus, by design.

## 1. The VM

| | |
|---|---|
| class | **srv** (`tag=40`) — your own migration runbook puts the cluster nodes in `srv`; `mgmt` is the admin plane, not a workload plane |
| bridge | `vmbr0` — measured today as already VLAN-aware (`vlan_filtering 1`, `vlan_default_pvid 1`) |
| address | `172.16.40.150` (proposed) — outside both srv DHCP pool ranges (`.20–.99`, `.200–.250`) and clear of every reservation |
| size | 2 cores / 4 GB / 20 GB is plenty: this cluster runs controllers, not workloads |
| DNS | `k3s.srv.hnatekmar.dev` — added by this PR as a literal; a *reservation* is the documented claim on the address and needs the VM's MAC, so it comes later |

```bash
# on the VM, after install
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable=traefik \
  --write-kubeconfig-mode=0644 \
  --tls-san=k3s.srv.hnatekmar.dev \
  --node-ip=172.16.40.150" sh -
```

Why those flags:

- `--disable=traefik` — k3s ships Traefik as its default ingress controller. The estate's ingress decision is
  still open (consistency argues for ingress-nginx, which the devops cluster runs), and leaving Traefik in
  would silently create a second ingress controller. An empty cluster keeps the question visible.
- `--tls-san` — the API cert covers the name, not just the address, so `KUBECONFIG` entries can use the name.
- `--write-kubeconfig-mode=0644` — so you do not fight permissions while `clusterctl` works.

## 2. Verify

```bash
kubectl get nodes -o wide                          # Ready, INTERNAL-IP 172.16.40.150
dig +short k3s.srv.hnatekmar.dev @172.16.10.1      # 172.16.40.150 — resolved by the router
ssh k3s.srv.hnatekmar.dev true                     # name-based access from charon/laptop
curl -sk https://k3s.srv.hnatekmar.dev:6443/version  # API answering on the name
```

## 3. What this step alone proves

That a management host can live in a class VLAN, be reached **by name** from the admin plane, and that
internal resolution works for a host that is not in `mgmt` — the same property the rest of the carve now
has. If step 2 fails on the name but works on the address, that is a DNS finding worth recording before
anything CAPMOX-shaped is blamed on the network.
