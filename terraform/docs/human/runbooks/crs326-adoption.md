# CRS326 and the island link

**Status:** The switch side is applied. The CRS317 side is hand-applied and outstanding.

This runbook configures the management escape port and the island link.

## Current state

The bridge adoption, the management escape port (`ether3`), VLAN filtering, and the management address (`172.16.10.2/20`) are already declared in `terraform/crs326/` and applied.

## Steps

### 1. Configure CRS317 management

The CRS317 side is hand-applied until `terraform/crs317` exists.

1. Set the CRS317 `ether1` MTU to 1500 before you plug the cable.
2. Plug the cable into CRS326 `ether24`.
3. Give the CRS317 NTP and DNS pointed at the router.

### 2. Verification

Verify that hardware offloading is active on all ports.
Check that every bridge port including bonds still reads `hw=yes` in the `/interface/bridge/port` menu.

Verify that a laptop on `ether3` can reach `172.16.10.2` and open WinBox.

## Rollback

Revert the Terraform changes in `terraform/crs326/` and apply.

## Related documents

- Agent source: `../../../crs326/README.md`
- Agent source: `../../agent/migration-runbooks.md`
- Agent source: `../../agent/network-wiring.md`
- Human map: `../infra-map.md`
