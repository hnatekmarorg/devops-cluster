# Stage 2, step 1 for the CRS326 — VLAN-aware, dual-addressed, nothing moved.
#
# The same shape as the router's step 1, with one difference that matters: **this switch keeps its
# compat address as well as gaining a mgmt one.** Martin's call (2026-09-15) and the right one —
# every tool, bookmark and script that talks to 172.16.100.2 keeps working, and the mgmt address
# arrives alongside rather than replacing anything. The compat address retires with the segment.
#
# Why the switch needs a mgmt address at all: it cannot route. On the router, the escape port
# reaches the *router's* management address; here, without an address in the same VLAN, a cable in
# `ether3` would reach nothing. 172.16.10.2/20 makes the escape port stand on its own, independent
# of whether the router's mgmt path is healthy.
#
# Not touched, deliberately: the dormant 192.168.88.1/24 on ether1. Martin described the storage
# network as "housed in the CRS317" with 192.168.88.1/24 — if this switch's copy is that network's
# gateway, deleting it would break storage, and it does nothing while the bond exists. Listed as a
# cleanup to do with him, not by me.
#
# Acceptance test after apply: 24/24 ports still `hw=yes` (bonds included — the classic offload
# killer), the compat LAN unaffected, 172.16.100.2 still answers, and a laptop on ether3 reaching
# **and managing** 172.16.10.2.

# ---------------------------------------------------------------------------
# The mgmt segment's L3 endpoint on this switch: a VLAN interface, catching the tag the bridge
# sends to the CPU.
# ---------------------------------------------------------------------------
resource "routeros_interface_vlan" "mgmt" {
  interface = var.bridge_interface
  name      = "vlan10-mgmt"
  vlan_id   = 10
  comment   = "managed-by:opentofu+gha devops-cluster (${var.switch_name})"
}

resource "routeros_ip_address" "mgmt" {
  address   = "172.16.10.2/20"
  interface = routeros_interface_vlan.mgmt.name
  comment   = "managed-by:opentofu+gha devops-cluster (${var.switch_name}) — escape port's segment"
}

# ---------------------------------------------------------------------------
# The bridge VLAN table.
#
# VLAN 1 (compat): the bridge is an UNTAGGED member so the switch's own 172.16.100.2 keeps
# answering exactly as it does today. `ether3` is absent on purpose — it is the escape port.
#
# VLAN 10 (mgmt): the bridge is a TAGGED member, because this segment's L3 is the VLAN interface.
# ---------------------------------------------------------------------------
resource "routeros_interface_bridge_vlan" "compat" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["1"]
  # `ether7` is absent for the same reason `ether3` is: it is no longer a compat port. It became the
  # out-of-band plane's access port (balteus IPMI, `.46`) — an untagged member of VLAN 10 only.
  untagged = ["balteus", "bukefalos", "ether4", "ether6", "ether8", "ether9",
    "ether10", "ether11", "ether12", "ether13", "ether14", "ether15", "ether17",
    "ether18", "ether19", "ether20", "ether21", "ether22", "sfp-sfpplus1", "sfp-sfpplus2",
  "bridge"]
  comment = "compat — everything not yet migrated; does not include ether3, ether7 or ether16"
}

resource "routeros_interface_bridge_vlan" "mgmt" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["10"]
  # Trunk membership extended in place, not in a row of its own: RouterOS allows exactly **one static
  # row per VLAN ID per bridge**, and a second one is refused at apply time with
  # `failure: vlan already added` (measured — that is how #53's first attempt failed, after a clean
  # plan). A dynamic row is not a precedent; the system creates those.
  #
  # Tagged on both uplinks: `ether18` toward the router (so this switch and the router share one mgmt
  # segment) and `ether4` toward the CSS610 (so charon, on that box, can live in mgmt). Untagged for
  # the two access ports that belong to the out-of-band/management plane: `ether3` (the escape hatch)
  # and `ether7` (balteus IPMI). Every other port keeps its compat pvid 1.
  tagged   = [routeros_interface_bridge.bridge.name, "ether18", "ether4"]
  untagged = ["ether3", "ether7"]
  comment  = "mgmt — the escape hatch, the IPMI's access port, tagged on both uplinks"
}

# ---------------------------------------------------------------------------
# Lab (30) — transport to the CSS610's Spark ports.
#
# No bridge membership on purpose: this switch has no L3 in the segment, so sending those frames to
# the CPU would only cost. The router terminates it (172.16.30.1/20 + `dhcp-lab`) and `ether18` carries
# the tag there. This is the only static row for VLAN 30 on this bridge, which is why it can have one
# of its own (see the note on the mgmt row).
#
# Before these entries exist, VLAN 30 has *no port on any device* and VLAN 10 does not cross the
# uplink — which is why the CSS610's per-port modes wait for this change to be applied.
# ---------------------------------------------------------------------------
resource "routeros_interface_bridge_vlan" "lab_trunk" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["30"]
  tagged   = ["ether18", "ether4"]
  comment  = "lab — transport only; the router terminates it"
}

# ---------------------------------------------------------------------------
# IoT (70) — same transport-only shape. `ether18` carries it to the router (L3 + DHCP), and `ether16`
# becomes the access port when the WiFi segment moves: one port serves the Deco BE22 (which cannot tag),
# the TV and the gaming PC, which is why the doc gives that segment one access port at PVID 70. `ether4`
# rides along for symmetry — a device behind the CSS610 can be placed in iot later without touching this.
# ---------------------------------------------------------------------------
resource "routeros_interface_bridge_vlan" "iot_trunk" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["70"]
  # ONE row per VLAN ID — RouterOS refuses a second static row (`failure: vlan already added`), so every
  # membership this segment has rides here.
  #
  # `ether18` (tagged) is the transport: the router holds the L3 (172.16.70.1/20) and `dhcp-iot`.
  # `ether4` is deliberately absent — that is the CSS610 uplink and no iot device sits behind it; the
  # segment's devices are reached through `ether16`, and a class only lists the ports that carry it.
  #
  # The port membership and the port's `pvid` travel together, which is why this is one row: `ether16`
  # is an UNTAGGED member and its `pvid` is 70 (see crs326/bridge.tf). Tagging it instead would leave
  # the segment's devices — a dumb switch, a Deco, a TV, a gaming PC, none of which can tag — receiving
  # VLAN 70 frames they cannot read, and would leave the probe sitting in compat.
  tagged   = ["ether18"]
  untagged = ["ether16"]
  comment  = "iot — tagged to the router on ether18; ether16 is the untagged access port to the devices"
}
