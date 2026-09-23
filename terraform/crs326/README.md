# `crs326/` — the main switch, adopted

Stage 1 for the CRS326-24G-2S+: **adoption only, zero behavioural change.** The bridge, its 24 ports
and both bonds are declared exactly as the device reports them; the plan is imports and nothing
else.

Contracts (runner, credentials, state, workflows) live in [`../README.md`](../README.md). The port
plan and the class design are in [`../docs/agent/vlan-port-assignment.md`](../docs/agent/vlan-port-assignment.md)
and [`../docs/agent/vlan-port-assignment.svg`](../docs/agent/vlan-port-assignment.svg).

## Why it exists before the change

The router taught this: the filtering step is a one-attribute diff (`vlan_filtering = true`) **only
because** the bridge domain was adopted first. Adopting and changing in the same plan makes the
review unreadable and the rollback ambiguous.

## The step after this file

`ether3` as an access port in the mgmt VLAN (its escape port), then `vlan_filtering = true` with
every port still on compat. One open question, to settle before that step: the switch's management
address lives in compat (`172.16.100.2`). Give it a mgmt address (`172.16.10.2/20`) so `ether3`
stands alone, or accept that reaching it depends on the router's mgmt path.

## The island switch's out-of-band link (this wave)

`ether24` leaves the idle `bukefalos` bond and becomes an untagged **mgmt** access port — the far end of
the CRS317's 1 G management port. The island's switch is otherwise reachable only from inside the island,
across the same LACP bond that carries every VM disk's iSCSI, so a bad bridge, VLAN or MTU change there is
a lockout with a console cable as the only way back. It is also the next device to be adopted by this tree,
and a plan needs a reachable endpoint.

Two constraints ride along, both measured 2026-09-19:

- **MTU 1500, not 9000.** Every CRS326 port is `l2mtu 1592`, so this link is not jumbo and cannot be. The
  CRS317's `ether1` must be set to `mtu = 1500` when it leaves that switch's bridge — *before* the cable is
  plugged. A 9000-byte sender on a 1592-byte segment drops only the large frames, so it reads as an
  intermittent fault rather than a broken link.
- **The CRS317 side is hand-applied for now** — bridge removal, its mgmt address, the forward-drop rules
  that keep the island unrouted, and NTP/DNS pointed at the router (which also fixes its 1972 clock, since
  both are directly connected in mgmt). That switch becomes `terraform/crs317` once it is reachable here.

## Traps inherited from the router module

- a stale checkout plans **destroys** — fetch before branching (`../scripts/tf-plan-check.sh`);
- adopting an object means declaring what it already has, or the provider plans to *clear* the
  field it reports (`vrf`, `dynamic_lease_identifiers`);
- the provider does not know every field this hardware reports; when it learns one, a plan shows a
  change that is not drift.
