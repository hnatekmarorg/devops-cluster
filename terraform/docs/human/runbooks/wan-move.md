# WAN move

**Status:** Applied and verified 2026-09-14. Use this runbook to verify the state or to recover.

This runbook moves the WAN uplink to a dedicated port. Use this runbook to stop the WAN from sharing the LAN L2 domain.

## Preconditions

- The RB5009 is configured.
- You have console access to the RB5009.

## Steps

### 1. Evidence of WAN uplink

Verify that `ether5` is the WAN uplink and `ether4` is the LAN uplink.
Run a download on a LAN host and check the interface counters in the `/interface` menu.
**NOTE:** `ether5` must show rx data from the ISP. `ether4` must show tx data to the LAN.

### 2. Move WAN interface

The PPPoE client is declared on `ether5` in `terraform/routeros/wan.tf` and `ether5` is no longer a bridge member.

The change is declared in the routeros module and applied by CI after review. Do not change the device by hand.

### 3. Verification

Perform these four checks on the RB5009:

1. Verify the PPPoE session is up in `/interface pppoe-client`. The status must be `R` (running).
2. Verify the default route is present in `/ip route`. The route must exist and point to the PPPoE client.
3. Verify the public address is unchanged in `/ip address`. The address must match the previous public IP.
4. Verify ISP MACs are gone from the LAN bridge host table in `/interface bridge host`. The output must not show ISP MACs on the bridge.

## Rollback

Restore the system from the pre-overhaul backup described in the router bootstrap runbook.

## Related documents

- Agent source: `../../agent/network-wiring.md`
- Agent source: `../../agent/router-bootstrap-runbook.md`
- Human map: `../infra-map.md`
