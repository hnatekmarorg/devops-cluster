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
| `ether1`+`ether2` | **LACP bond `balteus`** (802.3ad, L3+L4 hash) · runs on **one member** | bond as **trunk**, tagged `10,20,30,40,70`, pvid 1 → later parking | — | carries all 18 guest NICs. The second member was **repurposed by design** into the 10 Gbps NAS↔fabric link (now on CRS804 `ether2`), so 1 Gb on the flat-LAN side is expected, not a fault. Both CRS326 10 G SFP+ ports remain free if that ever needs lifting |
| `ether3` | down | **access, pvid 10** | mgmt | **escape port** — pre-assign in wave A |
| `ether4` | **UP → CSS610** | **trunk**, tagged `10,30` (+`10` for the CRS804 mgmt uplink) | — | the CSS610 is the middle hop for charon, the Sparks' management and the spine's management |
| `ether5`,`ether6`,`ether8`–`ether15`,`ether17`,`ether19`–`ether22` | down | spare (available for the gaming PC, IoT, printers as they are classified) | — | |
| `ether7` | **UP → HPE box #2** `3c:ec:ef:73:09:9d` | **access, pvid 40** | srv | the second physical server, to be integrated |
| `ether16` | **UP → dumb switch → AP + TV + gaming PC** | **access, pvid 70** | iot | **one cable, one segment** (Martin, 2026-09-14): the dumb switch cannot tag, so the AP, the TV and the gaming PC all land in the IoT VLAN. Everything on it reaches internal networks over the VPN |
| `ether18` | **UP → RB5009** | **trunk**, tagged `10,20,30,40,50,70`, pvid 1 → later tagged-only + pvid 999 | — | |
| `ether23`+`ether24` | **LACP bond `bukefalos`** (down) | bond as **trunk** when the server arrives | srv | already cabled for a 2-port LACP bond |
| `sfp-sfpplus1`,`sfp-sfpplus2` | down | spare · **opportunity:** 10 G uplink for balteus, or for the CSS610 hop | — | both 10 G and both unused while the server side runs at 1 G |
| gaming PC | behind `ether16` (the dumb switch) | **stays there — `vlan70-iot`** | iot | Martin's call: anything on that single line is IoT-class and reaches internals via VPN. No extra port needed |
| `vlan20-trusted` | — | **proposed to be dropped** | — | with charon in mgmt and the AP/TV/PC in iot, nothing is left for `trusted`; same for `vlan50-guest`. Running 4 classes instead of 6 is fewer rules and fewer default-allow surprises. Numbering stays free if a member appears later |

## CSS610 (`172.16.100.117`, SwOS Lite 2.21 · **hand config, no API**)

Port map supplied from the switch's own UI (2026-09-14) — it labels its ports by hand:

| Port | Name on the switch | Link | Proposed | Class |
|---|---|---|---|---|
| Port1 | — | no link | spare | — |
| **Port2** | `Charon` | 1 G | **access, pvid 10** | mgmt |
| **Port3** | `Spark 4` | 1 G | **access, pvid 30** | lab |
| **Port4** | `CRS04-4DDQ ETH1` | 1 G | **access, pvid 10** | mgmt |
| **Port5** | `Spark 3` | **100 M** ⚠ | **access, pvid 30** | lab |
| **Port6** | `Spark 2` | 1 G | **access, pvid 30** | lab |
| **Port7** | `CRS326 Port 4` | 1 G | **trunk**, tagged `10,30` | — |
| **Port8** | `Spark 1` | 1 G | **access, pvid 30** | lab |
| SFP+1, SFP+2 | — | no link | spare (10 G) | — |

**Finding on Port5: `Spark 3` negotiates 100 M while its three siblings do 1 G.** Management
traffic only, so nothing is broken — but 100 M on a gigabit port is the classic signature of a
damaged pair or a bad crimp, and it is worth a cable swap the next time someone is at the rack.

**Opportunity, not a task:** Port1 and both SFP+ ports here are free, and so are **both SFP+ ports
on the CRS326** — so the CSS610's uplink (today 1 G on `Port7`, carrying charon, the spine's
management and all four Sparks' management) could become a 10 G link whenever it is convenient.
Separate change; nothing in the carve depends on it.

## CRS804 (`172.16.100.113`, 7.24.2 · chip Marvell-98DX7335)

Note the two island networks this box touches: `bridge-compute` carries **`192.168.0.0/24`** (the
Spark fabric, with the NAS at `.0.250` over balteus' `vmbr4`) — *not* the `10.0.0.0/24` that the
switch's own address might suggest.

| Bridge | Port | Now | Proposed |
|---|---|---|---|
| `bridge1` | `ether1` | UP, mgmt only (~1 GiB in 3 weeks), software-bridged | **access, pvid 10** — gated: do this **only after charon is in `vlan10-mgmt`**, because this port is the only way into the box |
| `bridge-compute` | `ether2` + 4× QSFP-DD | the storage + RDMA fabric, by design | **not touched.** No VLAN filtering, ever |

## Reserved for known-future hardware

| Device | Evidence | Reservation |
|---|---|---|
| **atuin** (the new cluster node, `172.16.100.171`) | Martin, 2026-09-14: joins **after** the network upgrade; its NotReady Node object in the cluster is expected, not stale | **lab-class** access port on the main switch, **plus its IPMI (`172.16.100.123`, DHCP name "ipmi - atuin") in the mgmt VLAN**, and — per the rule below — a 10 G link into the storage island |
| **bukefalos** (second server) | already cabled as an idle LACP bond (`ether23`+`ether24` on the CRS326) | bond reserved as a **srv** trunk when it comes online |

**Rule (Martin, 2026-09-14): every Kubernetes node gets a 10 Gbps link into the storage network
(`192.168.88.0/24`).** For the five VM nodes that is already true — they sit on balteus' `vmbr2`
over `bond0`. A physical node like atuin therefore needs a 10 G port on the storage island's own
switch (CRS317), which is outside the LAN carve but must be reserved so the node arrives into a
finished network.

Reserving these now is the cheap direction: the ports sit in their future VLAN, unoccupied, and the
carve does not have to be revisited when the hardware arrives. The other direction (assigning them
compat "for now") means touching the same switch twice.

## Order of work this table implies

1. RB5009: move the LAN IP off `ether2` → bridge/VLAN, pre-assign `ether1` as the escape port, then enable filtering with everything still on compat.
2. CRS326: escape port, then filtering with everything on compat. ~~firmware upgrade first~~ — **done** (7.5 → 7.24.2 on 2026-09-14), so this device is no longer blocked.
3. CSS610: apply the hand config (trunk + per-port modes) with the recovery step written down first.
4. Move devices one access port at a time, verifying as we go.
5. CRS804: the single mgmt move, last of the switches.
6. balteus: per-VM tags on the PVE bridge.
7. Retire compat from the trunks (tagged-only + parking VLAN).
8. Egress classes (`wan-restricted`), log-only at rollout.
