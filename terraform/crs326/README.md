# `crs326/` — the main switch, adopted

Stage 1 for the CRS326-24G-2S+: **adoption only, zero behavioural change.** The bridge, its 24 ports
and both bonds are declared exactly as the device reports them; the plan is imports and nothing
else.

Contracts (runner, credentials, state, workflows) live in [`../README.md`](../README.md). The port
plan and the class design are in [`../docs/vlan-port-assignment.md`](../docs/vlan-port-assignment.md)
and [`../docs/vlan-port-assignment.svg`](../docs/vlan-port-assignment.svg).

## Why it exists before the change

The router taught this: the filtering step is a one-attribute diff (`vlan_filtering = true`) **only
because** the bridge domain was adopted first. Adopting and changing in the same plan makes the
review unreadable and the rollback ambiguous.

## The step after this file

`ether3` as an access port in the mgmt VLAN (its escape port), then `vlan_filtering = true` with
every port still on compat. One open question, to settle before that step: the switch's management
address lives in compat (`172.16.100.2`). Give it a mgmt address (`172.16.10.2/20`) so `ether3`
stands alone, or accept that reaching it depends on the router's mgmt path.

## Traps inherited from the router module

- a stale checkout plans **destroys** — fetch before branching (`../scripts/tf-plan-check.sh`);
- adopting an object means declaring what it already has, or the provider plans to *clear* the
  field it reports (`vrf`, `dynamic_lease_identifiers`);
- the provider does not know every field this hardware reports; when it learns one, a plan shows a
  change that is not drift.
