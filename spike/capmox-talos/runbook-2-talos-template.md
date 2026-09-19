# Runbook 2 — the Talos *nocloud* Proxmox template

CAPMOX clones a **VM template**, so one has to exist per Talos version. It must be the **`nocloud`**
platform image, not `metal`: `nocloud` is the Talos platform that reads cloud-init NoCloud `user-data` —
which is the mechanism H1 depends on.

## 1. Build the image (image factory — the tool the estate already uses)

Schematic: start minimal — `siderolabs/qemu-guest-agent` so Proxmox can read the guest's address — and add
extensions only when a workload needs them (nvidia, iscsi, nvme-cli, …).

Fetch the **disk image** for `nocloud-amd64` from the factory page for your schematic. The URL shape is:

```
https://factory.talos.dev/image/<schematic-id>/<talos-version>/nocloud-amd64.raw.xz
```

(The *installer* URL that the machine config references is a different path —
`factory.talos.dev/nocloud-installer/<schematic-id>:<talos-version>` — and it is what goes into
`manifests/cluster-talos-proxmox.yaml`. Confirm both on the factory page rather than by pattern-matching
this file.)

**Pin the version deliberately.** The estate's current specs disagree with themselves — the CP config says
Talos `v1.12.1`, the worker config template says `v1.34.1` (a Kubernetes version in a Talos field), and the
install images are `v1.11.2` and `v1.13.5`. Whatever you pick, put it in one place and make the manifests
agree.

## 2. Import it as a template

```bash
# on balteus
cd /var/lib/vz/template/iso
curl -LO "<the factory disk image URL from step 1>"
xz -d nocloud-amd64.raw.xz

qm create 9000 --name talos-nocloud-template --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single --ostype l26 \
  --serial0 socket --vga serial0
qm set 9000 --citype nocloud                        # Talos' platform reads NoCloud — state it, don't inherit it
qm importdisk 9000 nocloud-amd64.raw <storage>      # in this estate the import landed on `iscsi`
qm set 9000 --scsi0 <storage>:vm-9000-disk-0 --boot order=scsi0
qm set 9000 --ide2 local-lvm:cloudinit --agent enabled=1
qm template 9000
```

- **`<storage>` is whatever you actually imported onto**, and the `--scsi0` line must name *that* storage's
  volume. Written from the docs, this file said `local-lvm`; on the first real run the import landed on
  `iscsi` and the `--scsi0` line was skipped — which left the image in `unused0` with `boot: order=net0`.
  A clone would then have booted into the network, Talos would never have started, and CAPMOX would have
  been blamed for a template problem. The verification in step 3 is what catches it.
- The **cloud-init drive** (`--ide2 …:cloudinit`) is the bootstrap channel: CAPMOX writes into it, Talos'
  `nocloud` platform reads from it. Without it, H1 cannot work — this is the one line that matters.
- `--citype nocloud` is PVE's default for Linux ostypes, but H1 depends on it *exactly*, so it is stated
  rather than inherited.
- `--agent enabled=1` only reports anything if the image carries the `siderolabs/qemu-guest-agent`
  extension from step 1 — that is how CAPMOX reads the VM's address back.
- **Do not set the VLAN on the template** — the class tag belongs on the *clone* (`vlan: 40` in the machine
  template), so one template can serve every class.
- Record the VMID here and in the manifest: **`templateID: 9000`**.

## 3. Verify — attached, not merely imported

```bash
qm config 9000 | grep -E "^(boot|scsi0|ide2|agent|citype|unused|template)"
```

Expect `scsi0: <storage>:vm-9000-disk-0`, `boot: order=scsi0`, `citype: nocloud`, `agent: enabled=1`,
`template: 1` — and **no `unused0` line**. `unused0` is the entire failure mode: the disk is present but not
attached to the VM.

### As built, 2026-09-16

| | |
|---|---|
| VMID / node | `9000` on `balteus` |
| disk | `iscsi:vm-9000-disk-0`, 4248M — the nocloud image, imported onto `iscsi` |
| boot | `order=scsi0` |
| cloud-init | `ide2: local-lvm:vm-9000-cloudinit,media=cdrom` with `citype: nocloud` |
| console | `serial0: socket`, `vga: serial0` |
| agent | enabled |
| **cpu** | **`x86-64-v2-AES`** (or `host`) — **never leave this unset** |

**The CPU type is the silent killer.** Proxmox's default is `kvm64`, which predates the **x86-64-v2**
microarchitecture level **Talos requires** (Sidero's own Proxmox guide says so explicitly). Leave `cpu`
unset on the template and every clone dies in early boot with a SIGILL panic and, because Talos ships
`panic=30`, **reboots forever**. The 2026-09-17 signature, measured on two such clones, is worth
recognising because the VM looks healthy from the outside:

```
status=running, uptime=55m, netin=212 bytes, netout=0 bytes, diskread=41.7 GB (disk is 4.2 GB)
```

Zero bytes out plus ~ten full reads of the disk = a boot loop that never reached the network. Prefer
**`x86-64-v2-AES`** over `host` on the template: it is the common denominator across the estate's CPUs
(Naples EPYC 7601 is v2, Rome 7642 is v3), so a clone stays bootable if it ever lands on a different host —
which is exactly what on-demand and Karpenter-provisioned nodes will do. `host` is fine for a VM that will
never move.

After the first clone, check that the clone got its **own** `smbios1` UUID —
`qm config <clone-id> | grep smbios1`. The template carries a fixed one, and two machines sharing an
identity is the kind of thing that surfaces later as a confusing providerID/address problem rather than as
itself.

Once a cluster exists, a cloned control-plane VM should boot `talos-nocloud`, fetch its config from the
NoCloud drive and join. If it boots and then waits forever, that is H1 failing — go to runbook 3 §4 and
check the two known Talos symptoms before touching the network.
