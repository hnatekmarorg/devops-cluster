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

qm importdisk 9000 nocloud-amd64.raw local-lvm
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0 --boot order=scsi0
qm set 9000 --ide2 local-lvm:cloudinit --agent enabled=1
qm template 9000
```

- The **cloud-init drive** (`--ide2 …:cloudinit`) is the bootstrap channel: CAPMOX writes into it, Talos'
  `nocloud` platform reads from it. Without it, H1 cannot work — this is the one line that matters.
- `--agent enabled=1` plus the guest-agent extension is what lets CAPMOX read the VM's address back.
- Storage: adjust `local-lvm` to whatever you use for VM disks.
- **Do not set the VLAN on the template** — the class tag belongs on the *clone* (`vlan: 40` in the machine
  template), so one template can serve every class.
- Record the VMID here and in the manifest: **`templateID: 9000`**.

## 3. Verify

```bash
qm config 9000 | sed -n '1,25p'   # expect: template: 1, scsi0, ide2 cloudinit, agent, serial0
```

Once a cluster exists, a cloned control-plane VM should boot `talos-nocloud`, fetch its config from the
NoCloud drive and join. If it boots and then waits forever, that is H1 failing — go to runbook 3 §4 and
check the two known Talos symptoms before touching the network.
