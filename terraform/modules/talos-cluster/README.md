# `talos-cluster`

Provisions a Talos cluster on Proxmox by cloning a PVE template. One module, one thin root per cluster.

```
terraform/modules/talos-cluster/   the factory
terraform/clusters/dev/            one cluster: ~25 lines of inputs
```

## What it encodes

Every row is something that failed, silently or with a misleading error, before it was understood.

| trap | what the module does about it |
|---|---|
| Talos panics on the Proxmox default CPU type | sets `cpu.type = "x86-64-v2-AES"` explicitly — never inherited |
| the nocloud platform does **not** assume DHCP | declares `machine.network.interfaces` with `dhcp = true`; without it the guest boots with no address and logs only `network is unreachable` |
| Talos' default NTP is unreachable from these VLANs | points `machine.time.servers` at the router; without a clock everything later fails for unrelated-looking reasons |
| the stock installer is the **metal** one | sets `machine.install.image` to `factory.talos.dev/nocloud-installer/<schematic>:<version>` |
| without an install the node runs from the image with a **RAM-backed `/var`** | re-adds the `UnattendedInstallConfig` document that triggers an install to disk |
| a legacy field collides with its document equivalent | patches `KubeletConfig` **by kind** (`cloud-provider=external`, without which the CCM can never populate a node's providerID) |
| no hostname patch is needed at all | the stock `HostnameConfig: {auto: stable}` resolves to the VM name via the platform instance-id — name the VMs well |
| clones must land on reserved addresses | MACs come in as inputs from the router's `dhcp.tf`, so names and addresses stay put across rebuilds |
| the VLAN tag decides reachability | declared explicitly on the cloned NIC; **the PVE template must carry the same tag**, because Karpenter's clones inherit it from the template instead |

## What the template must already provide

- `cpu` compatible with `x86-64-v2` (the module also sets it per clone)
- the class **VLAN tag on its NIC**, matching `vlan_id`
- the disk on **one** storage — a cloud-init drive on a second storage gives
  `Multiple storage IDs found for template`
- a `nocloud` Talos image, built with `siderolabs/qemu-guest-agent`

## What it hands back

`kubeconfig` (ArgoCD registration, and the CA the vault needs for `kubernetes` auth), `join_config` (the
`user-data` for the Secret a Karpenter NodeClass references), `talosconfig`, and the node addresses.

## Caveats

- **The state holds the cluster's secrets.** `talos_machine_secrets` generates the CA and tokens, so the
  state backend must be private and treated as secret material. Moving them to SOPS and passing them in as
  a variable is the better shape, and is not done yet.
- **The install path is the one unproven piece.** An earlier attempt stalled inside the guest and the cause
  needs the console; the module does it correctly *by configuration*, but the first real apply is where it
  gets verified.
