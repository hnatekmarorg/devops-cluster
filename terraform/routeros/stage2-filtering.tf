# Stage 2, step 1 — the bridge becomes VLAN-aware, and compat keeps working.
#
# Zero behavioural change is the requirement, and it survived a review of my own first draft:
# two things in that draft were wrong, and both would have hurt.
#
#   1. It moved the LAN address onto a new `vlan1-compat` interface. Unnecessary *and* risky:
#      the address is already configured on `ether2` but *actually* on `bridge` (`slave=True` in
#      /ip/address print), so it already behaves as a bridge address. Declaring it on the bridge
#      is bookkeeping, not cut-over — and keeping the bridge as the CPU's *untagged* member of
#      VLAN 1 means the router still sees `in-interface=bridge` for compat traffic, which is what
#      every existing firewall rule keys on ("drop all not coming from LAN", the LAN interface
#      list, the DHCP server bound to the bridge). A VLAN interface would have changed the
#      in-interface and quietly invalidated all of it.
#   2. It said nothing about the interface lists, so a laptop on the escape port could *ping* the
#      router (the input chain accepts ICMP early) and reach the internet (the forward chain has
#      no catch-all drop, and the WAN masquerade rule has no source restriction) — but it could
#      not SSH, WinBox or API the router, because `drop all not coming from LAN` matched it.
#      An escape hatch that cannot be used to configure anything is not an escape hatch.
#
# Rollback: `vlan_filtering = false` in bridge.tf, or the pre-change backup. The interface-list
# additions are additive and harmless on their own.
#
# Acceptance test after apply: north-south traffic unchanged · every bridge port still `hw=yes` ·
# a laptop on ether1 (static 172.16.10.50/20, gw 172.16.10.1, DNS 8.8.8.8) can ping, and *manage*,
# the router at 172.16.10.1.

# ---------------------------------------------------------------------------
# The LAN address — adopted exactly as it is, and deliberately NOT moved.
#
# The device reports it as `interface=ether2, actual-interface=bridge, slave=True`: RouterOS
# parents a slave-port address to the bridge in practice. Declaring the *configured* value makes
# this a pure adoption — 1 to import, 0 to change, nothing written — and it records a fact that
# looks wrong and is not, which deserves a comment rather than an edit.
#
# `vrf` is deliberately absent. The provider's schema has it and the device *reports* it (`main`),
# but RouterOS rejects it on write: the first apply of this file died with
# "from RouterOS device: unknown parameter vrf". A read-only field the schema offers as settable
# is a trap, not an invitation.
#
# id `*1` is its RouterOS internal id — `/ip/address print` shows it beside 172.16.100.1/24.
# ---------------------------------------------------------------------------
import {
  to = routeros_ip_address.lan
  id = "*1"
}

resource "routeros_ip_address" "lan" {
  address   = "172.16.100.1/24"
  interface = "ether2" # what the device reports; the bridge is where it actually lives
  comment   = "defconf"
  network   = "172.16.100.0"
  disabled  = false
}

# ---------------------------------------------------------------------------
# The bridge VLAN table.
#
# VLAN 1 (compat): the bridge is an **untagged** member, so the router's own L3 on this segment
# keeps arriving as `in-interface=bridge` — exactly what the existing rules, lists and the DHCP
# server expect. `ether1` is deliberately absent: it is the escape port and lives in VLAN 10.
#
# VLAN 10 (mgmt): the bridge is a **tagged** member, because this segment's L3 lives on a VLAN
# interface (`vlan10-mgmt`, created in stage 1). Tagged is how the CPU receives it.
# ---------------------------------------------------------------------------
resource "routeros_interface_bridge_vlan" "compat" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["1"]
  untagged = ["bridge", "ether2", "ether3", "ether4", "ether6", "ether7", "ether8", "sfp-sfpplus1"]
  comment  = "compat — everything not yet migrated; does not include ether1 (the escape port)"
}

resource "routeros_interface_bridge_vlan" "mgmt" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["10"]
  # Tagged on the uplink as well as on the bridge: this is what connects the router's mgmt segment to
  # the switch's, i.e. what turns the switch's escape port (`ether3`) into "a laptop here reaches the
  # router *and* the switches", and what lets a device behind the CSS610 (charon) live in mgmt.
  # Additive by construction: `ether4` keeps its untagged compat membership (pvid 1) untouched.
  tagged   = [routeros_interface_bridge.bridge.name, "ether4"]
  untagged = ["ether1"]
  comment  = "mgmt — the escape port's segment; tagged on ether4 so the switch shares it"
}

# ---------------------------------------------------------------------------
# Lab (30) on the uplink — transport only.
#
# The CSS610's Spark ports become lab access ports, which is useless without a path to this router:
# 172.16.30.1/20 (`vlan30-lab`) is the segment's L3 and `dhcp-lab` its address source. So VLAN 30
# needs a tagged member on `ether4`. Deliberately *only* tagged on the port here — the bridge keeps
# its own membership through RouterOS' dynamic entry for 30/40/60/70, which this does not touch.
#
# This row is a second entry for VLAN 30 alongside that dynamic one on purpose: RouterOS merges
# memberships across rows, and the estate already relies on that (the CRS326 carries one dynamic and
# one static row for VLAN 1). 40/60/70 get their tagged members when their devices move, not now.
# ---------------------------------------------------------------------------
resource "routeros_interface_bridge_vlan" "lab_trunk" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["30"]
  tagged   = ["ether4"]
  comment  = "lab — transport to the CSS610's Spark ports; L3 is vlan30-lab here"
}

# ---------------------------------------------------------------------------
# The class VLANs join the **LAN** interface list — for now, and deliberately.
#
# Today the router has no policy at all between internal segments: the forward chain has no
# catch-all drop (which is why the estate has internet by default-accept), and the only thing that
# *is* enforced is the input chain's "drop all not coming from LAN". Leaving the new segments out
# of that list would mean they could route but not be managed, be pinged but not administered.
#
# Stage 3 replaces this wholesale with the per-class matrix; until then, "inside" is the truthful
# description of every one of these segments. Recorded here rather than left implicit because a
# list entry is exactly the kind of thing that outlives its reason.
# ---------------------------------------------------------------------------
resource "routeros_interface_list_member" "class_vlans_lan" {
  for_each = toset(["vlan10-mgmt", "vlan30-lab", "vlan40-srv", "vlan60-vpn", "vlan70-iot"])

  list      = "LAN"
  interface = each.value
  comment   = "${local.managed_by} — until the stage-3 matrix replaces it"
}
