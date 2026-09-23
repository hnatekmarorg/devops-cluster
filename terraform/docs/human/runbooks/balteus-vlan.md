# Balteus VLAN migration

**Status:** Outstanding.

This runbook configures the balteus Proxmox host bridge to be VLAN-aware and moves guests into their class VLANs.

## Preconditions

- The CRS326 carries the `balteus` bond as a trunk member of all class VLANs (10, 30, 40, 60, 70).
- The router's uplink carries all class VLANs.
- The bond's port PVID is 1.

## Steps

### 0. Set up the lifeboat
Add an address to the `vmbr4` bridge to ensure access if `vmbr0` fails.
```bash
# in the vmbr4 stanza of /etc/network/interfaces, add:
#     address 192.168.0.38/24
#     # no gateway — the fabric has no router, and the default route must stay on vmbr0
ifreload -a
```
**NOTE:** The spine's `ether2` port reads `hw=false`. This means traffic between balteus and sparks is bridged by the spine's CPU.

### 1. Make the host bridge VLAN-aware
Prepare the bridge to carry tagged traffic.
```bash
cat /etc/network/interfaces                 # find the bridge over the balteus bond (vmbr0, most likely)
cp /etc/network/interfaces /root/interfaces.bak-$(date +%F)
# in that bridge's stanza add:
#     bridge-vlan-aware yes
#     bridge-vids 1-4094
ifreload -a
```
**CAUTION:** This step causes a short interruption on the bridge. Use the IPMI at `172.16.10.46` to fix the host if `ifreload` fails.
**Verify:** Run `ip -d link show vmbr0 | grep -i vlan` to confirm VLAN-filtering is active. Confirm the host answers on `172.16.100.38`.

### 2. Move guests to class VLANs
Move guests one at a time. Change the NIC tag and the guest's IP addressing.
```bash
qm config <id> | grep net0                   # note the current line for rollback
qm set <id> --net0 <bus>,bridge=vmbr0,tag=<vid>
```
**VLAN Tags:**
- 10: mgmt
- 30: lab
- 40: srv
- 60: vpn
- 70: iot

**Suggested Order:**
1. Stopped, disposable guests (e.g., `sandbox`).
2. Running sandboxes and CI.
3. Cluster nodes (`main-*`).
4. Keepers (e.g., gitea, authentik).
5. `truenas` (VM 101) last.

**Verify:** From inside the guest, confirm it takes an address from the class scope and reaches the class gateway and the internet.

## Verification

- All migrated guests reach their respective class gateways.
- All migrated guests reach the internet.
- `truenas` continues to answer on `172.16.40.148` and `192.168.0.250`.

## Rollback

- Per guest: Use `qm set <id> --net0 <original line>` and revert addressing to compat (`172.16.100.x`).
- Whole host: Remove `bridge-vlan-aware yes` and `bridge-vids 1-4094` from `/etc/network/interfaces` and run `ifreload -a`.

## Related documents

- Agent source: `../../agent/balteus-vlan-migration-runbook.md`
- Human map: `../infra-map.md`
