# CSS610 cut-over runbook

**Status:** Outstanding. This is the first window in which devices move.

This runbook moves devices from the compat LAN to their class VLANs on the CSS610 access switch. Use this during the first device migration window.

## Preconditions

- The router's `ether4` and the CRS326's `ether18` and `ether4` carry tagged VLAN 10 and 30.
- Verify VLANs by reading `/interface/bridge/vlan` on the router and the CRS326.
- The compat LAN answers on `172.16.100.1`, `172.16.100.2`, `172.16.100.113`, and `172.16.100.117`.
- Download a config backup of the CSS610 from *System → Backup*.
- Take a screenshot of the current per-port VLAN state.
- Prepare a laptop and patch cable.
- Ensure the person performing the work is not on charon.

## Steps

### 1. Set up the recovery perch
Connect a laptop to `Port1`. Log into `http://172.16.100.117`.
Confirm the laptop reaches `172.16.100.1`, `172.16.100.2`, and `172.16.100.113`.
Make sure the patch cable is within reach.

### 2. Configure Port7 as trunk
Set `Port7` to carry the native/compat VLAN untagged and tagged members for VLAN 10 and 30.
**Verify:** Confirm that charon, the four Sparks, the spine, the CSS610, the CRS326, and the router all answer.
**Rollback:** If a device drops, set `Port7` back to compat-only from the laptop.

### 3. Move Sparks to lab access
Move `Port8` (Spark 1), `Port6` (Spark 2), `Port5` (Spark 3), and `Port3` (Spark 4) to lab access (untagged VLAN 30) one port at a time.
For each port, run these commands:
```bash
ping -c2 172.16.30.<suffix>              # 136 / 137 / 112 / 110
curl -s http://172.16.30.<suffix>:8000/v1/models | head
```
**NOTE:** For Spark 1, update `/root/workspace/lmproxy/config.yaml` (`http://172.16.100.136:8000` → `http://172.16.30.136:8000`) and run `systemctl restart lmproxy`.
**Rollback:** Set the port back to compat (untagged VLAN 1).

### 4. Move charon to mgmt access
**Before this step:** Connect a laptop to the CRS326's `ether3`. Confirm the laptop gets a mgmt lease and reaches `172.16.10.1` and `172.16.10.2`.
Set `Port2` (charon) to untagged VLAN 10 only.
**Verify:** Confirm charon takes a lease from the mgmt pool and reaches the network gear.
**Rollback:** From the laptop on `Port1`, set `Port2` back to compat.

## Verification

- Every Spark's inference endpoint answers on `172.16.30.{136,137,112,110}:8000`.
- charon answers on its mgmt address and reaches the router and switches.
- CSS610 management `172.16.100.117` is reachable from the laptop on `Port1`.
- CRS326 shows `24/24 hw=yes` in `/interface/bridge/port`.
- Router plan/apply shows no changes.
- VLAN 10 is tagged on `ether4` and `ether18`.
- VLAN 30 is present with the uplink ports.
- CRS326 `ether3` remains untagged mgmt.

## Rollback

| Broke | Undo |
|---|---|
| `Port7` (everything behind the box drops) | From the `Port1` laptop: set `Port7` to compat-only |
| one Spark | Set that port back to compat |
| charon | From the `Port1` laptop: set `Port2` to compat |
| the box itself unreachable | Restore the config backup from the preconditions |

## Related documents

- Agent source: `../../agent/css610-cutover-runbook.md`
- Human map: `../infra-map.md`
