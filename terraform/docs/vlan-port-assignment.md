# VLAN port assignment — the stage-2 contract

**The diagram is the artifact: [`vlan-port-assignment.svg`](vlan-port-assignment.svg)** (rendered
from the same measured tables, one line per port). This file keeps only what a diagram cannot
carry: the conventions, the reservations, and the order of work. The as-is wiring and the reasoning
behind each class live in [`network-wiring.md`](network-wiring.md).

## Conventions — they apply to every device

| Convention | Why |
|---|---|
| Trunks keep `pvid=1` (compat) as native until the last device has moved | that *is* the migration mechanism: an untagged frame on a trunk still lands in the compat segment, so unmigrated devices keep working untouched |
| Access ports get `pvid=<class>` + `frame-types=admit-only-untagged-and-priority-tagged` | a device that cannot tag stays in its class and cannot inject someone else's |
| After the last move: trunks become tagged-only with `pvid=999` | 999 is unrouted, has no gateway and no DHCP — a mis-cabled untagged device lands nowhere useful instead of silently in a real segment |
| One spare port per switch is pre-assigned to mgmt **before** anything else changes | the escape hatch: a laptop on that port still reaches the router and the switches |
| Acceptance test per device: every bridge port — bonds included — still reads `hw=yes` after `vlan-filtering=yes`, then a connectivity smoke test | RouterOS silently moves a non-offloadable port to the CPU bridge; that is a throughput change, not a cosmetic one |

Trunk tag list, final: **`10, 30, 40, 60, 70`**. `trusted` (20) and `guest` (50) are retired and
unallocated; `vpn` is 60 (`172.16.96.0/20`, so balteus can place a VM in the zone rather than only
tunnelling clients into it).

## Reserved for known-future hardware

| Device | Reservation |
|---|---|
| **bukefalos** (second server) | already cabled as an idle LACP bond (`ether23`+`ether24` on the CRS326) → reserved as an **srv** trunk |
| ~~atuin~~ | **parked (2026-09-14)** — introduced later; nothing reserved beyond the rule below |

**Rule (Martin, 2026-09-14): every Kubernetes node gets a 10 Gbps link into the storage network
(`192.168.88.0/24`).** True for the five VM nodes already (they sit on balteus' `vmbr2` over
`bond0`); a physical node would need a 10 G port on the storage island's own switch (CRS317) —
outside the LAN carve, but know it before the hardware arrives.

## Order of work this implies

1. **RB5009** — `ether1` as the escape port, LAN IP off `ether2` onto the bridge/VLAN, then
   `vlan-filtering=yes` with everything still on compat: zero behaviour change.
2. **CRS326** — escape port `ether3`, then the same filtering step. ~~upgrade first~~ **done**
   (7.5 → 7.24.2), so this device is no longer blocked by anything.
3. **CSS610** — hand config (trunk on `Port7`, per-port modes), with the recovery step written
   down first: it has no API, and it sits on the path to the work PC and the Spark management.
4. **Move devices one access port at a time**, verifying each.
5. **CRS804** — the single management move, **last** of the switches, gated on charon already
   being in mgmt.
6. **balteus** — per-VM tags on the PVE bridge (`bridge-vlan-aware`, then `tag=` per NIC).
7. **Retire compat** from the trunks (tagged-only + parking).
8. **Egress classes** (`wan-restricted`, log-only at rollout).

## Two notes the diagram has no room for

- **The WAN port is `ether5` on the RB5009** — measured, and it is the one port the carve must
  never tag: the PPPoE client currently rides the *bridge*, so wave 2 moves it onto the port first.
- **Negotiated link rates hide.** RouterOS' API reports each port's *advertised* speed, not what it
  negotiated — which is how `Spark 3` sat at 100 M (a damaged cable pair, since swapped) with
  nothing anywhere reporting a problem. SwOS' Link tab and WinBox's "Rate" column show the truth.
