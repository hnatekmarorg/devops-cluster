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
# The LAN address: adopted, and moved from the slave port it is configured on to the bridge it is
# already actually using. Same address, same prefix, same in-interface as today.
# id `*1` is its RouterOS internal id — `/ip/address print` shows it beside 172.16.100.1/24.
# ---------------------------------------------------------------------------
import {
  to = routeros_ip_address.lan
  id = "*1"
}

resource "routeros_ip_address" "lan" {
  address   = "172.16.100.1/24"
  interface = routeros_interface_bridge.bridge.name
  comment   = "defconf"
  network   = "172.16.100.0"
  disabled  = false
  vrf       = "main"
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
  tagged   = [routeros_interface_bridge.bridge.name]
  untagged = ["ether1"]
  comment  = "mgmt — the escape port's segment; reachable whatever compat does"
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
