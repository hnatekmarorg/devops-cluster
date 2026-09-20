# Network wiring — measured, plus the proposed VLAN carve

Two views of the same network, on purpose:

| View | File | What it is for |
|---|---|---|
| **Architecture & intent** | [`network-wiring.svg`](network-wiring.svg) | the shape of the estate, the fabric, the DNS/DHCP trap, and what the carve is *for* — the narrative a reviewer reads first |
| **Port-level map** | [`network-port-map.svg`](network-port-map.svg) | every live port with its measured occupant and MAC count, plus the proposed class per segment — the artifact stage 2 is actually written against |
| **Current state (as-is map)** | [`network-map-current.svg`](network-map-current.svg) | the whole estate as measured — physical/L2 in one panel, every network (LAN, both islands, WAN, vestigial, reserved) in the other |
| **Port assignment (stage 2 contract)** | [`vlan-port-assignment.md`](vlan-port-assignment.md) | per device, per port: access vs trunk, PVID, tagged set, class — the table the module gets written from |

**A note on state vs target:** the diagrams say `one flat bridge, 0 VLAN entries` because that is
**today** — nothing on this estate is tagged yet, on any link. Everything about classes and trunks
describes the **target**. 
**Sources (read from the devices, 2026-09-14 — not from memory or the plan):** MNDP/LLDP
neighbour tables (`/ip/neighbor`), bridge MAC tables (`/interface/bridge/host` — this is
what names each port's occupants), bridge port and VLAN configuration
(`/interface/bridge/{port,vlan}`), DHCP leases, `/ip/dns`, `/ip/firewall/nat`. Everything
below is **measured** or explicitly marked **TBC**; an invented box would be worse than a gap.

## The model, because it is easy to misread

VLAN membership is decided by **device class** (what the device may reach), never by which
socket it happens to use. The port is only the *mechanism*: an access port (untagged, PVID =
the class) for a single device; a trunk (tagged) for switch uplinks, the router, and the
Proxmox bridge once VM NICs carry tags. Stage 1 of the IaC (`../routeros/`) touches **no
ports at all** — VLAN interfaces, gateways and address lists only, inert until the bridge
becomes VLAN-filtering. That is why this map comes first: the port map is the *input* to the
policy, not the policy.

## The WAN is currently *inside* the LAN bridge

Measured on the RB5009 (`/interface/pppoe-client`):

```
name        interface   add-default-route   use-peer-dns
t-mobile    bridge      true                true
```

The PPPoE client is bound to **`bridge`**, not to a physical port or a VLAN. Consequences:

- the WAN port is inside the **same broadcast domain as every LAN device**. Precisely: the bridge
  floods the *client's* PPPoE discovery/session frames (broadcast/multicast) to every port, while the
  ISP's unicast replies are delivered only to the router's session MAC — so LAN devices can *see* the
  ISP's concentrator (and, with PPPoE client software, attempt their own session), but they are not
  handed the ISP's traffic. The evidence is the MAC table: three ISP-side MACs
  (`18:5b:00:…`, `28:de:e5:…`, `c4:b8:b4:…`) learned on `ether5` alongside a router MAC;
- **which port is which, measured not assumed** (2026-09-14): 20 MB downloaded from a LAN host moved
  `ether5` **rx +24.76 MiB** (data arriving from the ISP) and `ether4` **tx +24.64 MiB** (data handed
  to the LAN); every other port stayed at zero. So `ether5` is the WAN uplink and `ether4` is the LAN
  uplink to the CRS326 — confirmed by counters rather than by reading cables. `sfp-sfpplus1` (the
  `172.16.101.0/24` subnet) carries **no link**: Martin confirms it is a leftover from earlier
  experiments and unused, so it is vestigial config rather than a live segment — a cleanup candidate,
  and excluded from the map and the carve;
- and it is the single most important thing to get right **before** the VLAN carve: a port that
  carries the WAN while being a bridge member will be handed a VLAN class by any mechanical
  application of the table above, and the WAN will move or break with it.

**Proposed pre-carve step** (needs a change window — the PPPoE session re-establishes, so internet
blips for a few seconds):

1. take `ether5` out of the bridge (it is the ISP uplink — the Huawei in bridge mode, Martin
   2026-09-14; it is the only live port with non-LAN MACs behind it);
2. move the PPPoE client onto that port (or onto a dedicated WAN VLAN with no LAN members);
3. verify: PPPoE up, default route present, the public address unchanged, and the ISP MACs gone from
   the LAN bridge's host table.

After that the LAN bridge has no WAN members at all, which is what makes "the WAN is never in a LAN
VLAN" a property rather than a promise — and the carve's port table stops containing a port it must
not touch.

## DNS: the router is not a resolver (found 2026-09-14)

The CRS326 "cannot reach the internet" — but it can. Measured from the switch itself:

```
ping 172.16.100.1     2/2 replies      (gateway — L2 and router input fine)
ping 8.8.8.8          2/2 replies      (routing and NAT fine)
ping one.one.one.one  resolve failed   ← the actual fault
```

`/ip dns` on the switch points at **172.16.100.1**, and the router has
`allow-remote-requests = no` — **it does not answer queries.** So every name lookup on a
statically addressed device fails, while DHCP clients are fine: the DHCP network hands out
`dns-server = 8.8.8.8`. That split is visible on the devices themselves — the CRS804 is a DHCP
client with a *dynamic* DNS server (`8.8.8.8`) and resolves; the CRS326 is static, points at the
router, and cannot. It is also why the CRS326's clock ran nine days behind: NTP by name.

Two ways out, and they are different decisions:

- **(a) Point the device's DNS at real resolvers** (`8.8.8.8, 1.1.1.1`) — one line per device,
  consistent with what DHCP already hands out. A fix, not a design change.
- **(b) Make the router the LAN's resolver** (`/ip dns set allow-remote-requests=yes`) — this is
  what the carve's DNS phase wants anyway (split-horizon answers for VPN clients), and it would
  activate the static entries the router already carries (`ipmi-balteus` → `.46` and friends)
  for the whole LAN. It is also a decision: a resolver on the router must be scoped to the LAN
  and VPN segments by firewall, never exposed to the WAN.

Recommended order: (a) now, per device, to unblock; (b) deliberately in the carve's DNS step,
with the firewall rule and the VPN scope landing at the same time.

**Status 2026-09-14: (a) applied to the CRS326 and verified.** It now resolves and responds —
`ping one.one.one.one` 2/2 at 8 ms, `ping upgrade.mikrotik.com` 2/2 at 54 ms — so the device
"could not reach the internet" for exactly the reason above and nothing else. The CRS804 keeps
its DHCP-provided resolver, and the router keeps `8.8.8.8, 1.1.1.1` for its own lookups.

Two follow-ons from the same pass, both per-device bootstrap rather than design:

- **NTP is disabled on both switches** (`/system ntp client` → `enabled=no`), which is why the
  CRS326 drifted nine days before this. The router already runs NTP against the europe pool.
  Enable it on the switches in the same sitting as the read-group change below — a switch whose
  clock drifts makes every log, backup filename and certificate check lie.
  **Status 2026-09-19:** the CRS326 now syncs against the europe pool directly (verified,
  `synchronized`). The router additionally **serves** time as of the same date
  (`terraform/routeros/ntp.tf`, `routeros_system_ntp_server`) — which is what lets a device with no
  egress sync at all. First consumer: the storage island's CRS317, pointed at `172.16.10.1` over its
  new management link, since it is deliberately given no default route (and its time zone still needs
  setting from `manual`/`+00:00` to `Europe/Prague`).
- The router carries **nine static DNS entries** that currently reach nobody, because it does not
  serve DNS. They become useful the moment (b) happens — that is the argument for (b) being a
  deliberate step rather than an accident.

## Stale configuration found in the same pass

Leftovers, all dormant, each with a way to wake up:

| Where | Leftover | Why it is dormant | Why it matters |
|---|---|---|---|
| CRS326 `ether1` | `192.168.88.1/24` — the **storage network's** address | `ether1` is a bridge slave (via the `balteus` bond), so the address is inactive | pull `ether1` out of the bond — which is exactly what "delete the LACP" does — and `.88.1` becomes live, **duplicating the CRS317's address** on the storage island |
| CRS326 routes | `172.16.101.0/24 via 172.16.100.1` | the work subnet has no link (see below) | a route to a network that no longer exists; dead weight in every route table read |
| Router NAT | **nine** `masquerade` rules with `src=172.16.100.0/24` and `out-interface-list=LAN`, plus the real one (masquerade out `t-mobile`) | they permit nothing extra — the internet path is the `t-mobile` rule | looks like repeated hairpin-NAT attempts; harmless, but nine copies of one rule is drift worth retiring during the port-forward audit |
| CRS326 `ether1` link | bond member with **no link** (`balteus` runs on `ether2` alone) | a single-member LACP bond still forwards | if atuin's cable is in `ether1`, this is the port "we will reuse", and deleting the bond is what frees it |

## The two islands, and who has a foot in both

Neither island is on the LAN, and neither is touched by the carve — but both matter to it,
because the guests below are bridges between the islands and the LAN.

| Island | Fabric | Addressing | Reachable from the LAN? |
|---|---|---|---|
| **Compute / RDMA fabric** | CRS804 `bridge-compute` — 4× QSFP-DD at 200 G to the Sparks, `ether2` 10 G to balteus | the fabric itself is **`192.168.0.0/24`**; the **NAS is `192.168.0.250`** there; the switch's own address on that bridge is `10.0.0.1/24`; PFC `pfc-roce`, jumbo MTU 9000. balteus' `vmbr4` (over `eno2`) is the NAS↔fabric link | no (one bridge, no LAN member) |
| **Storage network** | **CRS317-1G-16S+** (16×SFP+ 10 G, management port *empty*) → air-gapped | **`192.168.88.0/24`**; balteus' own address `192.168.88.20` on `vmbr2` over `bond0`; the NAS (TrueNAS) at `.88.25` | no — deliberately |

**Dual-homed guests** (measured 2026-09-14 from the PVE API — a LAN NIC *and* a storage NIC,
i.e. exactly the boxes that can bridge the two domains): `truenas` (**four** NICs: vmbr0, vmbr2,
vmbr3, vmbr4), `main-1`…`main-4` (the devops cluster), `kubernetes-master`, `cpu-worker0`,
`gpu-worker0`, `inference`, `coder`, `portainer`, `proxy` (VM 107 and CT 131), `authentik-and-proxy`,
`gitea` (CT 110), `github-dind`, `box`, `sisters`… ~18 in total. `headscale` and `sister-hermes`
are LAN-only.

Consequences worth stating plainly:

- The storage island is an **isolation/availability design, not a trust boundary** — any of those
  ~18 guests could forward between the islands if it routed. That is acceptable here; it is
  written down so nobody mistakes it for a security wall later.
- Storage traffic **stays off the LAN**, which is why the carve does not disturb it (and why the
  10 G NAS path on CRS804 and this 10 G island are two different things).
- Each dual-homed guest must be handled as multi-homed during the carve: its LAN NIC gets a class,
  its storage NIC stays exactly where it is.
- **Correction to an earlier reading:** the devops-cluster config referencing NFS at
  `192.168.88.25` was recorded as "stale". It is not — `.88.25` is the NAS on the storage network,
  and the cluster nodes reach it because they are dual-homed.

Open questions this raised: balteus' **`vmbr3` carries `192.168.1.2/24`** (an unexplained third
network) and **`vmbr4` bridges `eno2`** with no host address (used by TrueNAS). Both need an
answer before the map is complete.

## Layer 1 — as it is

**Posture:** one flat L2 domain. Every device runs one bridge with `vlan-filtering` **off**,
every port `pvid=1, frame-types=admit-all`, and **not one bridge VLAN entry exists** anywhere.
Every port therefore defaults into the compat segment — which is why an unmapped port breaks
**silently**.

| Device | State | Live ports with measured occupants |
|---|---|---|
| **RB5009** (`172.16.100.1`, **7.24.2** — upgraded 2026-09-14 from 7.12.1) | one bridge, LAN IP `172.16.100.1/24` on **`ether2`** — a bridge slave whose link is **down** (the plan's cut-over risk #1) | `ether4` UP · 1 Gb → CRS326 `ether18` (33 MACs behind it); `ether5` UP → 3 MACs, AP or small switch **TBC**; `sfp-sfpplus1` = the work subnet `172.16.101.1/24` |
| **CRS326-24G-2S+** (`172.16.100.2`, **7.24.2** — upgraded 2026-09-14 from **7.5/2022**) | 24 ports + 2 SFP+, one flat bridge; 6 ports live | `ether18` → RB5009; **`balteus`** = an **LACP bond** (`ether1`+`ether2`, 802.3ad) → the PVE host, **18 guest NICs** — one member was **repurposed by design** as the 10 Gbps NAS↔fabric link (the cable now lands on CRS804 `ether2`), so the bond runs on a single 1 Gb member; `ether4` → CSS610 → the rest; `ether7` → HPE box #2 `3c:ec:ef:73:09:9d`; `ether16` → **deco-BE22** AP + 4 WiFi clients; **`bukefalos`** = a second LACP bond (`ether23`+`ether24`), idle, waiting for that server. Two 10 G SFP+ ports sit unused while the server side runs at 1 G |
| **CSS610-8G-2S+** (SwOS 2.21, `.117`) | **no RouterOS API** → outside IaC, hand-config only | *Not a leaf:* the measured MAC table shows it is the middle hop for **charon (work PC, `.227`)**, the **spark1-4 management NICs**, and **CRS804's management uplink** |
| **CRS804-4DDQ** (`.113`, **7.24.2** — upgraded 2026-09-14 from 7.23.3) | **two bridges, and only one of them carries traffic** | `bridge1`: **`ether1` only — management access, nothing else** (~1 GiB in three weeks; being single-port, CPU bridging is expected here, not a fault). `bridge-compute` (`10.0.0.1/24`) is the **storage + RDMA fabric by design**: 4× QSFP-DD at `200G-baseCR4` → spark1..4 (**hardware-offloaded**, ~300 TiB each way since boot) plus **`ether2` → balteus' 10G NAS link** (~43.6 TiB received since boot, **software-bridged**, no drops or errors, average ~24 Mbit/s) |
| **Endpoints** | — | `balteus` (Proxmox, 46 guests, 19 running) carries the live devops cluster `main-*` and the VIP `.15` (ARP'd by `main-4`); the Sparks have a management NIC on the flat LAN (`.110/.112/.136/.137`) **and** a RoCE NIC on the fabric |

### The air-gapped 10 G island (not on the LAN, not in scope)

A **CRS317-1G-16S+** (16×SFP+ 10 G + 1 GbE management) sits next to the CRS326, densely cabled
in its SFP+ ports, with its **1 GbE management port empty** — an air-gapped 10 G island
(Martin, 2026-09-14). It is unreachable from the LAN and therefore outside both the module and
the VLAN carve. It was also **not** part of the firmware upgrade, which only covered LAN-connected
devices.

Two things to confirm: **what hangs off it**, and whether **anything is dual-homed** between it
and the LAN — a box with a NIC on each side bridges the two islands and would silently bypass the
segmentation. Related: the CRS326 reports **both SFP+ ports down**, although the rack photo shows
what looks like a cable in the left cage — if that cage is meant to link to the CRS317, the link is
not coming up and that is worth a look before any VLAN work.

### Corrections this pass produced

1. The Sparks' fabric-side addressing is **`192.168.0.x`**, not the `192.168.192.0/24` the plan assumes.
2. The RB5009's uplink to the main switch is **1 Gb** (`ether4` ↔ `ether18`); the 10 G SFP+ serves the *work* subnet instead.
3. CRS326 already carries **hand-named ports** (`balteus`, `bukefalos`) — the class intent is partly expressed on the device already.
4. The RoCE fabric lives on a **separate bridge** on the CRS804, so "leave the fabric alone" is a **per-bridge** decision, not a per-port one.
5. **CSS610 is a middle hop, not a leaf** (this pass): cutting or mis-trunking it takes out the work PC, the Sparks' management *and* the spine's own management.
6. **`balteus` and `bukefalos` are LACP bonds, not renamed ports** — `ether1`+`ether2` and `ether23`+`ether24` respectively. For the carve this means the *bond* is the bridge port that carries the trunk; slaves are never configured individually.
7. **The NAS path and the balteus bond are the same port, moved.** The second bond member now terminates on CRS804 `ether2` (bridge-compute) and carries a balteus VM NIC — that is TrueNAS reaching the Sparks at 10 Gbps. One cable, two facts.

### Post-upgrade verification (2026-09-14)

All three RouterOS devices were upgraded to **7.24.2** (RB5009 from 7.12.1, CRS326 from 7.5/2022,
CRS804 from 7.23.3). Re-measured and diffed against the pre-upgrade inventory taken the same
morning:

| Check | Result |
|---|---|
| Switch chips | unchanged (`88E6393X`, `98DX3236`, `98DX7335`) |
| Hardware offload | unchanged: 9/9 · 24/24 · 4/6 — the same two CRS804 ports stay software-bridged |
| Bonds | `balteus` (`ether1`+`ether2`) and `bukefalos` (`ether23`+`ether24`) intact |
| Fabric | PFC profile **`pfc-roce`** still applied to the four live QSFP ports, 200 G queue-3 shaping intact; all four fabric links + the NAS link + the mgmt uplink up |
| Config drift | **none** — bridges, bridge ports, VLAN entries, addresses, user groups and NTP are identical to the pre-upgrade inventory (only volatile fields differ: RSTP debug strings, ARP) |

Caveat: the inventory script does not capture the QoS/PFC menu, so PFC was verified by presence and
profile, not by a field-level diff. Adding that menu to the inventory is a small follow-up that
makes the next upgrade a byte-level check.

### Resolved on 2026-09-14 (Martin)

| Was TBC | Answer |
|---|---|
| Whose box is `bukefalos`? | another server, to be integrated later — think *second balteus* |
| CRS326 `ether2/5/6/8–15/17/19–22` — empty or occupied? | it is a **"dumb" switch with servers on random ports** → trace only the **live** ports; 5 are live, 4 identified above, `ether2` is the one to look at |
| CRS804 `ether2`? | **direct 10 G link to balteus**, used to give balteus its NAS path |
| CSS610 occupants? | mainly the **Sparks** and **charon** (the work PC) |
| IoT/printers — own VLAN or onto `.40`? | **own VLAN** → `vlan70-iot` below (`.60` stays reserved for WireGuard clients) |

## Layer 2 — proposed, for review

| Class | Subnet (gateway) | Host addressing | Candidates from the measurements | Port mechanism |
|---|---|---|---|---|
| mgmt | `172.16.0.0/20` (`172.16.10.1/20`) | `172.16.10.x` | `charon` (work PC), network-gear management, IPMIs (`.123` atuin, `.46`), `bukefalos` later | access on the CSS610 port for charon; tagged on every switch uplink |
| lab | `172.16.16.0/20` (`172.16.30.1/20`) | `172.16.30.x` | **AI compute**: spark1-4 management, `.189`; sandboxes | trunk to balteus (per-VM tags) + access on spark ports |
| srv | **`172.16.32.0/19`** (`172.16.40.1/19`) | `172.16.40.x` | `balteus` + its keepers (truenas, gitea, authentik, matchbox, headscale), the `3c:ec:ef` box, **and the devops cluster nodes** (see below) | **balteus' uplink becomes a trunk** — the largest single change |
| → service VIPs | *inside srv, one subnet* | `172.16.48.1 – 172.16.63.254` | **the MetalLB pool** — 4,094 addresses | **L2 announcement** — possible precisely because pool and nodes share srv's /19 |
| iot | `172.16.64.0/20` (`172.16.70.1/20`) | `172.16.70.x` | **the whole WiFi segment**: `ether16` → dumb switch → Deco BE22 (all SSIDs, it cannot tag) + TV + gaming PC | one access port (`ether16`), PVID 70 |
| vpn | **`172.16.96.0/20`** (`172.16.96.1/20`) | `172.16.96.x` | **VMs placed in the VPN zone** (balteus: any guest that should be VPN-only) *and* WireGuard clients, routed in from `172.16.112.0/20` | **VID 60 on the trunk**; clients arrive on the tunnel — one zone, two transports, one policy via the `vpn-nets` list |
| compat | `172.16.100.0/24` | — | everything not yet migrated; **fabric excluded entirely** | stays until the last wave |
| ~~trusted~~ `172.16.20.0/24` · ~~guest~~ `172.16.50.0/24` | retired | — | the gaming PC shares one cable with the AP and TV → IoT; the WiFi segment is one untrusted segment | numbers stay unused |
| parking | VLAN **999** | — | end-state trunks only: a tag that passes and reaches nothing | bridge-VLAN entry — no interface, no address |

**One subnet per class, sized by its block** (2026-09-14). Each VLAN interface carries the class
prefix with its own address at the `.1` of the host area — `srv` is `172.16.40.1/19`, not
`/24`. This is the difference between *documenting* room and *having* it: hosts number from
`.40.x` by habit, the MetalLB pool takes `.48–.63`, and both are addresses in one subnet.

**That placement is what lets MetalLB run in L2 mode** — pool and announcing nodes in the same
subnet, no routing protocol, no FRR privileges on the speaker, no BGP peer group on the router.
BGP stays the upgrade path if L2's single-announcer behaviour ever becomes a real constraint;
the range works unchanged there.

**Balteus must be able to place a VM in any class** (Martin, 2026-09-14) — `lab`, `srv` and `vpn`
named. That is what the trunk is *for*: the uplink carries every tag, so placing a guest is a
one-line change in the VM's config (`tag=` on the NIC) rather than a cabling job. Practically:

- PVE's bridge becomes VLAN-aware (`bridge-vlan-aware yes`, `bridge-vids 2-4094`), and each guest
  NIC carries its class tag; the 46 existing guests migrate one at a time — this is the largest
  single change of the carve and the reason the port table calls balteus' uplink a trunk.
- The PVE host's **own** management address belongs in `srv` (it is a keeper); its storage NIC
  stays on the storage island, and `vmbr3` (host-internal fast path) is untouched.
- Consequence worth stating rather than discovering: same-host, same-class guest pairs keep
  switching inside balteus; **cross-class pairs go via the router**, so policy applies to them —
  which is the point, but it also means the router's CPU sees that traffic.
- One caveat: the bond carrying all of this is **1 Gb on a single live member**. Guests' *storage*
  and *fabric* traffic is on separate paths, so this is not a capacity problem today — but it is
  the reason the bond deletion question keeps coming up rather than being cosmetic.

**Where the cluster nodes live is the one consequence to settle.** For L2, the nodes must be in
the pool's subnet, so either they move to `srv` (recommended: the cluster hosts the keepers —
gitea, the IdP, the registry — and it needs real internet egress for image and ACME pulls, which
`lab` deliberately restricts) or they stay in `lab` and the pool moves into lab's block instead.
Recommendation: **cluster → srv**, leaving `lab` meaning "AI compute and sandboxes", which is the
cleaner pair of definitions.

## Constraints that decide the order of work

1. **`bridge-compute` is not touched, and that is by design** (confirmed 2026-09-14): it is the storage + RDMA fabric — the four QSFP ports to the Sparks and `ether2` to balteus' NAS link belong on the same bridge on purpose. Because of that, **the CRS804 needs no VLAN trunk at all**: its only non-fabric port is `ether1`, a single-member management bridge. Its entire VLAN footprint is "move the management IP into the mgmt VLAN" — and that one is gated, because `ether1` is the only way into the box: do it only once the admin workstation is already in `vlan10-mgmt`, or the switch becomes unreachable from the compat LAN and the fix is a physical trip.
   - **Pre-existing finding, not caused by the carve:** `ether2` (the NAS link) is **software-bridged** while the four QSFP ports are hardware-offloaded — so traffic between balteus and the Sparks crosses the CPU. It is real but modest (~43.6 TiB in three weeks ≈ 24 Mbit/s average, no drops, CPU load 0%), so nothing is broken; the open question is whether it is a per-port capability of the 98DX7335 or a flag that can be set, and whether a *sustained* transfer is CPU-limited. Worth one reversible experiment and a measurement **before** VLAN work lands there, so a throughput limit is never mistaken for a VLAN problem.
2. **CSS610 must be configured by hand** and it sits on the path to the work PC, the Sparks' management and the spine's management. Any trunk design has to name its ports explicitly and be verified physically.
3. **WiFi is one untrusted segment, and that is accepted** (Martin, 2026-09-14): the Deco cannot tag SSIDs, so it keeps its whole uplink in one VLAN — no per-SSID VLAN mapping, no hardware change. Access to internal networks is expected over the **VPN**, not over WiFi. Two consequences are promoted to requirements:
   - **The resolver must serve VPN clients** (split-horizon: internal names → internal addresses over the tunnel, everything else forwarded). The VPN zone (`172.16.60.0/24`) needs DNS/NTP reachability from day one, not as a later rule.
   - **WireGuard becomes load-bearing before WiFi is isolated.** Today the phone and any wireless client reach internal services directly over the flat LAN; once the WiFi segment is untrusted, that path is the tunnel. Sequencing therefore changes: the VPN (and its DNS path) lands **before or with** the WiFi isolation, not after it as an optional phase-5 nicety.
   - Still worth one decision: with a single untrusted segment, IoT and guest devices share L2 and can talk to each other. If that matters, the **MikroTik AP** (which can tag per SSID) can carry a second SSID for IoT while the Deco stays single-VLAN.
4. **balteus' uplink becomes a trunk** with per-VM tags on the PVE bridge (46 guests) — the most delicate change of the carve.
5. **The router's LAN IP sits on a bridge slave whose link is down.** Moving it onto the bridge/VLAN interfaces is the first real cut-over risk.
6. **DHCP leases are 10 minutes** — fast propagation works in both directions.

## Why the DNS ordering matters (the risk that outranks the VLANs)

| Measured today | Consequence |
|---|---|
| DHCP hands out **`8.8.8.8`** (10-minute leases) | every client resolves *internal* names through the public internet |
| `.dev` records on Cloudflare point at the **private** `172.16.100.15` | it works only because public DNS returns a private IP, plus NAT hairpin |
| **`allow-remote-requests: false`** | the router cannot serve DNS to clients even if they were pointed at it |
| only 9 legacy `*.dev.hnatekmar.xyz` static entries | no authority exists for the current scheme |
| `.15` is ARP'd by `main-4` | when the cluster moves to `vlan30` the VIP moves with it → Cloudflare must move in the same wave |
| wildcard TLS is **DNS-01 → Cloudflare**, `.dev` is HSTS-preloaded | cut the cluster's egress and renewals fail; an expired cert on an HSTS TLD is a hard failure, no click-through |

Four ways it bites: (1) `wan-restricted` on the AI boxes kills their DNS — the local resolver
must exist **before** egress classes; (2) deny-by-default east-west means a VLAN that cannot
reach `.15` resolves names and then fails to connect, which reads as "DNS is broken" but is
not; (3) the VIP moves with the cluster mid-wave; (4) cert renewal depends on the same path
staying intact.

**Therefore: DNS independence first (additive) → VLAN waves → egress classes last, log-only at rollout.**

## Still open

| # | Item | Why it matters |
|---|---|---|
| 1 | ~~CRS326 `ether2` / the degraded `balteus` bond~~ **resolved and by design** (Martin, 2026-09-14): one bond member was repurposed to give the NAS a 10 Gbps path onto the Spark fabric — that cable is the CRS804 `ether2` link measured below, carrying the NAS VM's traffic. Flat-LAN side of balteus is 1 Gb; the NAS path is 10 Gb. Nothing to fix | — |
| 2 | The RB5009 `ether5` segment (3 MACs) — AP or small switch? | decides trusted vs guest/IoT placement |
| 3 | Is the HPE box on `ether7` the machine the `bukefalos` port is reserved for? | if yes, the port name is stale; if not, `bukefalos` is unplugged |
| 4 | Which AP can tag VLANs per SSID? | gates guest + IoT on WiFi (constraint 3) |
| 5 | Does all network-gear management belong in `vlan10-mgmt`? | decides the tagged-VLAN set on every trunk |
| 6 | Spark *management* in `vlan30-lab` (with `wan-restricted`) or in `vlan10-mgmt`? | they are AI compute, but also infrastructure |
