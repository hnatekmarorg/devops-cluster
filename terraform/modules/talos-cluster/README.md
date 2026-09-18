# `talos-cluster`

Provisions a Talos cluster on Proxmox by cloning a PVE template. One module, one thin root per cluster.

```
terraform/modules/talos-cluster/   the factory
terraform/clusters/dev/            the entire dev cluster: ~25 lines of inputs
```

## What it encodes

Every row is something that failed before it was understood — most of them silently, or with an error
that pointed somewhere else. The authoritative version of each is the comment beside it in the module.

| trap | what the module does |
|---|---|
| Talos panics on the Proxmox default CPU type (`kvm64`) | sets `cpu.type` explicitly, never inherited |
| Talos on nocloud does **not** assume DHCP | declares `machine.network.interfaces`; without it the guest boots with no address and only logs `network is unreachable` |
| Talos' default NTP is unreachable from these VLANs | points `machine.time.servers` at the router — an unsynced clock breaks TLS, and every later step fails for unrelated-looking reasons |
| the stock install image is the **metal** one | derives `factory.talos.dev/nocloud-installer/<schematic>:<version>` |
| with no install the node runs from the image | sets `machine.install` — measured consequence of getting this wrong was a 2.1 GB RAM-backed `/var` on a 33 GB disk, then disk-pressure and nothing scheduling at all |
| the VLAN tag decides reachability | declared on the clone; Karpenter's clones inherit it from the template instead, so **the two must agree** |
| half-configured nodes look healthy from Proxmox | the module declares what the guest needs, because the guest's own logs are the only place the truth appears |

## Three limitations, stated rather than hidden

These are real, current, and each one cost time to establish. They are the rows a future reader is most
likely to trip over, so they are here rather than only in the code.

**1. Node names are NOT solved.** Nodes come up as `talos-<random>`. Setting a static hostname needs a
`HostnameConfig` *document* patch, and this provider's patch decoder rejects document kinds outright
(`"HostnameConfig" "v1alpha1": not registered`). The legacy `machine.network.hostname` collides with the
generated document instead. `set_hostnames` exists but is off by default and does not currently work.
Consequence is cosmetic — DNS points at addresses, which come from the router's reservations.

**2. Patches are applied at GENERATION, not apply time.** They go on the
`talos_machine_configuration` data source. This matters: at generation the generator resolves
legacy-vs-document conflicts, so legacy fields merge; the apply path would reject the same patch. It is
also why the by-kind document form cannot be used at all here.

**3. Structured OIDC authentication is impossible on Talos 1.14.** It needs a file visible inside the
kube-apiserver static pod: the file can be written but not mounted, because `extraVolumes` is missing
from the new `KubeAPIServerConfig` and `/etc/kubernetes` became a tmpfs
([siderolabs/talos#14394](https://github.com/siderolabs/talos/issues/14394)). The module therefore uses
the legacy `--oidc-*` flags, which read top-level claims only — fine here, because the realm propagates
roles into the `groups` array.

## What the template must provide

- `cpu=x86-64-v2-AES` (or the clone panics)
- the class VLAN tag on its NIC
- `agent: enabled=1`, and a schematic including `siderolabs/qemu-guest-agent`
- a single storage — a cloud-init drive on a second storage gives `Multiple storage IDs found for template`

## What it hands back

| output | used by |
|---|---|
| `kubeconfig` | ArgoCD registration, break-glass access |
| `oidc_kubeconfig` | credential-free kubeconfig (endpoint + public CA + `kubelogin` exec block) |
| `join_config` | Karpenter's `ProxmoxNodeClass` secret — rendered **without** a hostname so each clone names itself after its claim |
| `talosconfig`, `client_configuration` | operations |
| `nodes` | which address each node landed on |

## Repairing a broken cluster

`check_health` defaults true, and **set it false when repairing one**. The health data source reads the
cluster to decide, so with the API server down a normal apply deadlocks on
`talos_cluster_health: Still reading...` — it waits for the thing being repaired. That happened for real.
