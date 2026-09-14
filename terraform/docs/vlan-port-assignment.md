# VLAN port assignment — the stage-2 contract

This is the table the module gets written from and the thing to review **before** any config
lands. Every "now" column is measured (2026-09-14); every "proposed" column is a proposal for
Martin to correct. Class names and subnets follow the decision register Q2, plus `vlan70-iot`
and a parking VLAN (both marked as additions below).

## Conventions that apply to every device

| Convention | Why |
|---|---|
| **Trunks keep `pvid=1` (compat) as their native VLAN until the last device has moved.** | The migration mechanism: unmigrated devices keep working with zero changes. An untagged frame on a trunk lands in the compat segment, exactly as today. |
| **Access ports get `pvid=<class>` and `frame-types=admit-only-untagged-and-priority-tagged`.** | A device that cannot tag stays in its class and cannot inject someone else's VLAN. |
| **After the last move: trunks become tagged-only** (`admit-only-vlan-tagged`) with `pvid=999`. | A parking VLAN that is unrouted, has no gateway and no DHCP: a rogue or mis-cabled untagged device lands nowhere useful instead of silently in a real segment. |
| **One spare port per switch is pre-assigned to `vlan10-mgmt` before anything else changes.** | The escape hatch. If a VLAN change locks us out, a laptop on that port reaches the switch/router. |
| **Acceptance test per device: every bridge port — bonds included — must still read `hw=yes` after `vlan-filtering=yes`,** followed by a connectivity smoke test. | RouterOS silently moves a port to the CPU bridge when the config cannot be offloaded. That is a throughput change, not a cosmetic one. |

Additions to Q2 worth an explicit nod: **`vlan70-iot`** (your call, 2026-09-14) and **VLAN 999
as the parking VLAN** (new, for tag hygiene). `172.16.60.0/24` stays reserved for WireGuard.

## RB5009 (`172.16.100.1`, 7.12.1 · chip Marvell-88E6393X · 9/9 ports offloaded)

| Port | Now | Proposed | Class | Notes |
|---|---|---|---|---|
| `ether1` | down | **access, pvid 10** | mgmt | **escape port** — pre-assign in wave A |
| `ether2` | down, but carries `172.16.100.1/24` as a bridge slave | IP moves to the bridge / a VLAN interface | mgmt | cut-over risk #1: the LAN address must be moved first, and verified before anything else |
| `ether3` | down | spare | — | |
| `ether4` | **UP · 1 Gb → CRS326 `ether18`** | **trunk**, tagged `10,20,30,40,50,70`, pvid 1 → later tagged-only + pvid 999 | — | the estate's single uplink |
| `ether5` | UP · 3 MACs | **access** — class **TBC** | TBC | an AP or small switch with clients; decides trusted vs guest/IoT |
| `ether6`,`ether7`,`ether8` | down | spare | — | |
| `sfp-sfpplus1` | UP · `172.16.101.1/24` | **out of scope** | work subnet | its own /24 and L3; not part of this carve |
| bridge itself | mgmt IP `172.16.100.1/24` | `vlan10-mgmt` interface (+ compat kept until the end) | mgmt | |

## CRS326 (`172.16.100.2`, 7.5 · chip Marvell-98DX3236 · 24/24 offloaded)

| Port | Now | Proposed | Class | Notes |
|---|---|---|---|---|
| `ether1`+`ether2` | **LACP bond `balteus`** (802.3ad, L3+L4 hash) · `ether1` **DOWN** | bond as **trunk**, tagged `10,20,30,40,70`, pvid 1 → later parking | — | carries all 18 guest NICs. **Two findings:** the bond runs degraded on one member, and the flat-LAN side is 1 Gb — worth fixing/upgrading outside the carve |
| `ether3` | down | **access, pvid 10** | mgmt | **escape port** — pre-assign in wave A |
| `ether4` | **UP → CSS610** | **trunk**, tagged `10,30` (+`10` for the CRS804 mgmt uplink) | — | the CSS610 is the middle hop for charon, the Sparks' management and the spine's management |
| `ether5`,`ether6`,`ether8`–`ether15`,`ether17`,`ether19`–`ether22` | down | spare (available for the gaming PC, IoT, printers as they are classified) | — | |
| `ether7` | **UP → HPE box #2** `3c:ec:ef:73:09:9d` | **access, pvid 40** | srv | the second physical server, to be integrated |
| `ether16` | **UP → dumb switch → Deco BE22 + clients** | **access, pvid 50** | guest | one segment: the dumb switch cannot tag. Gaming PC moves off it (own port, pvid 20) |
| `ether18` | **UP → RB5009** | **trunk**, tagged `10,20,30,40,50,70`, pvid 1 → later tagged-only + pvid 999 | — | |
| `ether23`+`ether24` | **LACP bond `bukefalos`** (down) | bond as **trunk** when the server arrives | srv | already cabled for a 2-port LACP bond |
| `sfp-sfpplus1`,`sfp-sfpplus2` | down | spare · **opportunity:** 10 G uplink for balteus, or for the CSS610 hop | — | both 10 G and both unused while the server side runs at 1 G |
| gaming PC | currently behind `ether16` | **access, pvid 20** | trusted | own port; WAN-only matrix, internal access via VPN |

## CSS610 (`172.16.100.117`, SwOS Lite 2.21 · **hand config, no API**)

| Port | Now | Proposed | Class |
|---|---|---|---|
| uplink → CRS326 `ether4` | — | **trunk**, tagged `10,30` (+`10` for CRS804 mgmt) | — |
| charon (work PC) | — | access, pvid 10 | mgmt |
| CRS804 management (`ether1` of CRS804) | — | access, pvid 10 | mgmt |
| spark1–spark4 management NICs | — | access, pvid 30 | lab |
| 2× SFP+ | — | spare | — |

**I cannot read this switch's port mapping** (no API). To fill this table in I need the port
list from its UI, or a photo of the front panel with labels — the other session's diagram lists
its occupants but not which physical port is which.

## CRS804 (`172.16.100.113`, 7.23.3 · chip Marvell-98DX7335)

| Bridge | Port | Now | Proposed |
|---|---|---|---|
| `bridge1` | `ether1` | UP, mgmt only (~1 GiB in 3 weeks), software-bridged | **access, pvid 10** — gated: do this **only after charon is in `vlan10-mgmt`**, because this port is the only way into the box |
| `bridge-compute` | `ether2` + 4× QSFP-DD | the storage + RDMA fabric, by design | **not touched.** No VLAN filtering, ever |

## Order of work this table implies

1. RB5009: move the LAN IP off `ether2` → bridge/VLAN, pre-assign `ether1` as the escape port, then enable filtering with everything still on compat.
2. CRS326: **firmware upgrade first**, then escape port, then filtering with everything on compat; fix the degraded `balteus` bond member while in there.
3. CSS610: apply the hand config (trunk + per-port modes) with the recovery step written down first.
4. Move devices one access port at a time, verifying as we go.
5. CRS804: the single mgmt move, last of the switches.
6. balteus: per-VM tags on the PVE bridge.
7. Retire compat from the trunks (tagged-only + parking VLAN).
8. Egress classes (`wan-restricted`), log-only at rollout.
