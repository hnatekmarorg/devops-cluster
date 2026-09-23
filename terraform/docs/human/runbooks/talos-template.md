# Talos template

**Status:** Operational. Use this runbook when you must rebuild the Proxmox template.

This runbook describes the build of the Proxmox template used for cluster and Karpenter clones. Use it to create or update the Talos image.

## Preconditions
- SSH access to balteus.
- Access to the Talos image factory.

## Steps
### 1. Template Requirements
Ensure the template meets these requirements:
- CPU type: `x86-64-v2-AES`.
- `net0`: Use the class VLAN tag.
- Storage: Use one storage only.
- `net1`: Use storage bridge `vmbr2` at MTU 9000 with no tag.
- Agent: Enable `qemu-guest-agent`.
- Extensions: Include `iscsi-tools`, `util-linux-tools`, and `qemu-guest-agent`.

### 2. Rebuild Template
Use this command shape to rebuild the template:

```bash
curl -LO "<the factory disk image URL>"
xz -d nocloud-amd64.raw.xz
qm importdisk <VMID> nocloud-amd64.raw local-lvm
qm template <VMID>
```

**NOTE:** For detailed steps, see `spike/capmox-talos/runbook-2-talos-template.md`.

**CAUTION:** In `spike/capmox-talos/runbook-2-talos-template.md`, the rows regarding the VLAN tag on `net0` and the requirement for a cloud-init drive are wrong for this path.

## Verification
Verify the template configuration:

```bash
qm config 9000 | sed -n '1,25p'
```

## Rollback
Keep the previous template VMID before you update to the new version.

## Related documents
- `terraform/docs/agent/cluster-autoscaling.md`
- `spike/capmox-talos/runbook-2-talos-template.md`
