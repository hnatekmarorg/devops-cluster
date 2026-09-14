# Network wiring — measured, plus the proposed VLAN carve

Two views of the same network, on purpose:

| View | File | What it is for |
|---|---|---|
| **Architecture & intent** | [`network-wiring.svg`](network-wiring.svg) | the shape of the estate, the fabric, the DNS/DHCP trap, and what the carve is *for* — the narrative a reviewer reads first |
| **Port-level map** | [`network-port-map.svg`](network-port-map.svg) | every live port with its measured occupant and MAC count, plus the proposed class per segment — the artifact stage 2 is actually written against |
| **Tagging reference** | [`vlan-tagging.md`](vlan-tagging.md) | where an 802.1Q tag is inserted and stripped, who adds tags here and who never will, and the three gotchas that lock people out |

**A note on state vs target:** the diagrams say `one flat bridge, 0 VLAN entries` because that is
**today** — nothing on this estate is tagged yet, on any link. Everything about classes and trunks
describes the **target**. `vlan-tagging.md` exists so those two are never confused again.

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

## Layer 1 — as it is

**Posture:** one flat L2 domain. Every device runs one bridge with `vlan-filtering` **off**,
every port `pvid=1, frame-types=admit-all`, and **not one bridge VLAN entry exists** anywhere.
Every port therefore defaults into the compat segment — which is why an unmapped port breaks
**silently**.

| Device | State | Live ports with measured occupants |
|---|---|---|
| **RB5009** (`172.16.100.1`, 7.12.1) | one bridge, LAN IP `172.16.100.1/24` on **`ether2`** — a bridge slave whose link is **down** (the plan's cut-over risk #1) | `ether4` UP · 1 Gb → CRS326 `ether18` (33 MACs behind it); `ether5` UP → 3 MACs, AP or small switch **TBC**; `sfp-sfpplus1` = the work subnet `172.16.101.1/24` |
| **CRS326-24G-2S+** (`172.16.100.2`, **7.5** from 2022) | 24 ports + 2 SFP+, one flat bridge; **5 of 26 ports live** | `ether18` → RB5009; **`balteus`** (hand-named) → PVE host, **18 guest NICs**; `ether4` → CSS610 → the rest; `ether7` → HPE box #2 `3c:ec:ef:73:09:9d`; `ether16` → **deco-BE22** AP + 4 WiFi clients; `ether2` UP but silent **TBC**; **`bukefalos`** (hand-named) reserved, link down |
| **CSS610-8G-2S+** (SwOS 2.21, `.117`) | **no RouterOS API** → outside IaC, hand-config only | *Not a leaf:* the measured MAC table shows it is the middle hop for **charon (work PC, `.227`)**, the **spark1-4 management NICs**, and **CRS804's management uplink** |
| **CRS804-4DDQ** (`.113`, 7.23.3) | **two bridges** | `bridge1`: `ether1` → LAN mgmt uplink (29 MACs); `bridge-compute` (`10.0.0.1/24`, its own L2): `ether2` → **balteus 10G NAS path**, plus 4× QSFP-DD at `200G-baseCR4` → spark1..4 |
| **Endpoints** | — | `balteus` (Proxmox, 46 guests, 19 running) carries the live devops cluster `main-*` and the VIP `.15` (ARP'd by `main-4`); the Sparks have a management NIC on the flat LAN (`.110/.112/.136/.137`) **and** a RoCE NIC on the fabric |

### Corrections this pass produced

1. The Sparks' fabric-side addressing is **`192.168.0.x`**, not the `192.168.192.0/24` the plan assumes.
2. The RB5009's uplink to the main switch is **1 Gb** (`ether4` ↔ `ether18`); the 10 G SFP+ serves the *work* subnet instead.
3. CRS326 already carries **hand-named ports** (`balteus`, `bukefalos`) — the class intent is partly expressed on the device already.
4. The RoCE fabric lives on a **separate bridge** on the CRS804, so "leave the fabric alone" is a **per-bridge** decision, not a per-port one.
5. **CSS610 is a middle hop, not a leaf** (this pass): cutting or mis-trunking it takes out the work PC, the Sparks' management *and* the spine's own management.

### Resolved on 2026-09-14 (Martin)

| Was TBC | Answer |
|---|---|
| Whose box is `bukefalos`? | another server, to be integrated later — think *second balteus* |
| CRS326 `ether2/5/6/8–15/17/19–22` — empty or occupied? | it is a **"dumb" switch with servers on random ports** → trace only the **live** ports; 5 are live, 4 identified above, `ether2` is the one to look at |
| CRS804 `ether2`? | **direct 10 G link to balteus**, used to give balteus its NAS path |
| CSS610 occupants? | mainly the **Sparks** and **charon** (the work PC) |
| IoT/printers — own VLAN or onto `.40`? | **own VLAN** → `vlan70-iot` below (`.60` stays reserved for WireGuard clients) |

## Layer 2 — proposed, for review

| Class | Subnet | Candidates from the measurements | Port mechanism |
|---|---|---|---|
| mgmt | `172.16.10.0/24` | `charon` (work PC), network-gear management, IPMIs (`.123` atuin, `.46`), `bukefalos` later | access on the CSS610 port for charon; tagged on every switch uplink |
| trusted | `172.16.20.0/24` | **wired personal devices without WiFi in them** — the gaming PC behind `ether16` gets its own port and lands here, firewall matrix **WAN-only** (internal access = VPN). Resolved 2026-09-14: the class survives | access ports |
| lab | `172.16.30.0/24` | devops cluster `main-*` **and the VIP `.15`**, sandbox, spark1-4 management, `.189` | trunk to balteus (per-VM tags) + access on spark ports |
| srv | `172.16.40.0/24` | `balteus` + its keepers (truenas, gitea, authentik, matchbox, headscale), the `3c:ec:ef` box | **balteus' uplink becomes a trunk** — the largest single change |
| guest | `172.16.50.0/24` | **the WiFi segment**: `ether16` → the dumb switch → Deco BE22 (all its SSIDs, since it cannot tag) + whatever else hangs there; internal access via VPN only | one access port (`ether16`), PVID 50 |
| iot | `172.16.70.0/24` | wired IoT (printers, TV, `.167` embedded) and — if we split SSIDs on the MikroTik AP — the IoT SSID; the Tapo P110s and Shelly plug currently sit on WiFi | access ports |
| compat | VLAN 1, `172.16.100.0/24` | everything not yet migrated; **fabric excluded entirely** | stays until the last wave |

## Constraints that decide the order of work

1. **`bridge-compute` is not touched.** It carries both the RoCE fabric and balteus' 10 G NAS path. PDU/RDMA does not survive a router, so an "isolated VLAN" would sever GPU RDMA.
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
| 1 | CRS326 `ether2` is UP with nothing learned — what is plugged in? | a live-but-silent port is exactly what a carve forgets |
| 2 | The RB5009 `ether5` segment (3 MACs) — AP or small switch? | decides trusted vs guest/IoT placement |
| 3 | Is the HPE box on `ether7` the machine the `bukefalos` port is reserved for? | if yes, the port name is stale; if not, `bukefalos` is unplugged |
| 4 | Which AP can tag VLANs per SSID? | gates guest + IoT on WiFi (constraint 3) |
| 5 | Does all network-gear management belong in `vlan10-mgmt`? | decides the tagged-VLAN set on every trunk |
| 6 | Spark *management* in `vlan30-lab` (with `wan-restricted`) or in `vlan10-mgmt`? | they are AI compute, but also infrastructure |
