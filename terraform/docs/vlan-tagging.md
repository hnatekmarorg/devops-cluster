# How tagging works here — and where it does *not*

Written because the port map's `one flat bridge, 0 VLAN entries` note reads like a design
statement. It is not: it is the **current state**. Today nothing on this estate is tagged.
This page is the reference for the cut-over, so the two states are never confused again.

## Today: no tags exist

Every bridge on RB5009 / CRS326 / CRS804 (`bridge1`) / CSS610 runs `vlan-filtering=off`, has
**zero VLAN entries**, and every port is `pvid=1, frame-types=admit-all`. Consequence: every
frame on every link is an ordinary untagged Ethernet frame, all devices share one broadcast
domain, and **no 802.1Q header exists anywhere on the wire**. Calling it "VLAN 1" is only a
shorthand for that.

## Where the tag is, and when it appears

The tag is 4 bytes inserted into the Ethernet header between the source MAC and the EtherType:

```
untagged:  [ DA 6 ][ SA 6 ][ EtherType 2 ][ payload … ][ FCS ]
tagged:    [ DA 6 ][ SA 6 ][ 8100 2 ][ PCP/DEI/VID 2 ][ EtherType 2 ][ payload … ][ FCS ]
                            └ TPID     └ 3b PCP · 1b DEI · 12b VLAN id
```

Three rules cover everything:

1. **Ingress = classification, no bytes change.** A switch receiving an *untagged* frame tags
   it internally with that port's **PVID**. Nothing is written to the frame.
2. **The tag is inserted by the device transmitting on a *tagged* member port** — i.e. at the
   first switch port that leads to a trunk (an uplink, the router, a hypervisor). The FCS is
   recomputed.
3. **The tag is stripped by the device transmitting on an *untagged* member port** — the
   access port toward the end device, which sees a normal frame and never knows a VLAN existed.

If every port on the path is an access port in the same VLAN, no tag is ever created.
A device that tags its own traffic (Proxmox VM NIC, VLAN-capable AP, NIC subinterface) is not
"tagged by the switch" — the switch only *validates* the tag, and drops the frame if the port
is not a tagged member (that is ingress filtering).

### Hop by hop, a gaming PC in VLAN 20 reaching the internet

```
PC (untagged)
  └─▶ edge switch access port   [untagged member of VLAN 20, PVID 20]   classification only
       └─▶ trunk uplink         [tagged member of VLANs 10,20,30,50]    TAG INSERTED HERE
            └─▶ CRS326 / CRS804 / CSS610 trunks                         tag preserved, per-VID forwarding
                 └─▶ RB5009 bridge port [tagged member of VLAN 20]      tag consumed by /interface/vlan → L3
                      └─▶ routed out the WAN
```

## Who will add tags in the target design, and who never will

| Device | Tags? | Where the tag comes from |
|---|---|---|
| CRS326 / CRS804 / RB5009 | yes | per-port `pvid` + `/interface/bridge/vlan` tagged/untagged membership, once `vlan-filtering=yes` |
| CSS610 (SwOS) | yes, but **by hand** (no API) | its VLAN tab; uplink becomes a trunk |
| MikroTik AP | yes, per SSID | SSID → VLAN |
| Deco BE22 | **no** | — (accepted: its whole uplink is one untrusted segment; internal access is via VPN) |
| balteus (Proxmox) | yes | the **VM NIC** carries the tag (or PVE `tag=` on the veth) — the "wave B" per-VM work |
| RB5009 L3 | consumes | `/interface/vlan` on the bridge — that is where a VLAN becomes a routable interface |
| PCs, dumb switches, printers, NAS | **never** | they only ever see untagged frames |

**Where tags will first exist in this estate:** on the switch-to-switch trunks, on the router's
VLAN interfaces, and on balteus' PVE bridge. Nowhere else — a PC, the Deco, or anything behind
a dumb switch stays untagged for its whole life.

## The `ether16` segment (Deco BE22 + gaming PC) — settled 2026-09-14

The little switch behind `ether16` is a **dumb switch** (Martin, 2026-09-14), so it cannot tag
and everything behind it is **one** L2 domain, i.e. one VLAN. That means:

- `ether16` becomes the **untrusted segment**: the Deco, its WiFi clients, and whatever else
  hangs off that dumb switch.
- The **gaming PC gets its own cable to its own CRS326 port**, so it is not forced into that
  segment by sharing the uplink. Its class is `vlan20-trusted` (a wired personal device) with
  the firewall matrix allowing **WAN only** — if it ever needs something internal, that comes
  over the VPN like everything else (Martin, 2026-09-14). This also answers the earlier open
  question: `vlan20-trusted` survives, as wired personal devices, without WiFi in it.
- Where the tag appears for the PC: nowhere on its own cable; the CRS326 inserts it when the
  frame leaves toward a trunk, exactly as in the walkthrough above.

## Three gotchas, in order of nastiness

1. **An untagged frame arriving on a trunk port inherits that port's PVID.** That is how the
   compat segment keeps working during the migration — and how a device ends up in the wrong
   VLAN with no error message anywhere.
2. **Enabling `vlan-filtering=yes` can lock you out.** The switch's own management path (the
   bridge/CPU port) must already be a member of the VLAN its management address will live in.
   On the CRS326 that is a WinBox/console trip to fix; on the **CSS610 there is no API at all**,
   so it is a physical one. This is why wave A pre-assigns one spare access port per switch to
   the mgmt VLAN as an escape hatch.
3. **Tags arriving where they are not expected are dropped.** Access ports should run
   `frame-types=admit-only-untagged-and-priority-tagged`; two devices straddling a VLAN boundary
   without routing is a silent black hole, not an error.
