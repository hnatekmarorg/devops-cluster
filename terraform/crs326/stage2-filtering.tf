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
  untagged = ["balteus", "bukefalos", "ether4", "ether5", "ether6", "ether7", "ether8", "ether9",
    "ether10", "ether11", "ether12", "ether13", "ether14", "ether15", "ether16", "ether17",
    "ether18", "ether19", "ether20", "ether21", "ether22", "sfp-sfpplus1", "sfp-sfpplus2",
  "bridge"]
  comment = "compat — everything not yet migrated; does not include ether3 (the escape port)"
}

resource "routeros_interface_bridge_vlan" "mgmt" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["10"]
  tagged   = [routeros_interface_bridge.bridge.name]
  untagged = ["ether3"]
  comment  = "mgmt — the escape port's segment; reachable whatever compat does"
}

# ---------------------------------------------------------------------------
# The uplink carries both new segments, one entry per VLAN so each segment's carriage reads in one
# place (and both are creates, not edits of live rows).
#
# VLAN 10 (mgmt) — `ether18` joins this switch's mgmt segment to the router's; `ether4` carries it to
# the CSS610, where charon moves into mgmt. `ether3` stays the untagged escape port and every port
# keeps its compat pvid 1: nothing moves here.
#
# VLAN 30 (lab) — transport to the CSS610's Spark ports. No bridge membership on purpose: this switch
# has no L3 in the segment, so sending those frames to the CPU would only cost. The router terminates
# it (172.16.30.1/20 + `dhcp-lab`) and `ether18` carries the tag there.
#
# Before these entries exist, VLAN 30 has *no port on any device* and VLAN 10 does not cross the
# uplink — which is why the CSS610's per-port modes wait for this change to be applied.
# ---------------------------------------------------------------------------
resource "routeros_interface_bridge_vlan" "mgmt_trunk" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["10"]
  tagged   = ["ether18", "ether4"]
  comment  = "mgmt — carried on both uplinks: ether18 to the router, ether4 to the CSS610"
}

resource "routeros_interface_bridge_vlan" "lab_trunk" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["30"]
  tagged   = ["ether18", "ether4"]
  comment  = "lab — transport only; the router terminates it"
}
