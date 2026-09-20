# CRS804 management migration

**Status:** Outstanding. Do this last of the switches, after charon is in mgmt.

This runbook moves the management address of the CRS804 spine switch into the mgmt VLAN. This is the last switch migration.

## Preconditions

- charon must be in the mgmt VLAN.
- The CRS804 has a management address on `bridge1` (member `ether1`).
- The fabric bridge `bridge-compute` must not be touched.

## Steps

### 1. Move management address to mgmt VLAN
**WARNING:** A mistake on `ether1` cannot be fixed remotely. The fix requires a physical trip to the device.
Change the management address on `bridge1` from the compat LAN to the mgmt VLAN (VLAN 10).
As the source provides no command block, perform this action via the RouterOS API or WinBox.
**Verify:** Confirm the CRS804 answers on its mgmt address `172.16.10.201`.

## Verification

- The CRS804 management address `172.16.10.201` is reachable from the mgmt VLAN.
- The `bridge-compute` fabric remains operational.

## Rollback

- No remote fallback exists for `ether1`.
- Physical action: Connect to the device via console cable to restore the management address.

## Related documents

- Agent source: `../../agent/migration-runbooks.md`
- Network wiring: `../../agent/network-wiring.md`
- Switch README: `../../../crs326/README.md`
- Human map: `../infra-map.md`
