# Stage 2, step 1 — the bridge becomes VLAN-aware, and the compat segment keeps working.
#
# Zero behavioural change is the requirement here, and the four edits below are what that costs:
# every port stays untagged in its current segment, so no frame is classified differently and no
# device notices. What changes is *underneath*: the bridge now has a VLAN table, and the router's
# own addresses sit where a VLAN-aware bridge expects them.
#
# What this buys, and why the order is fiddly:
#   * `ether1` becomes an access port in the mgmt VLAN (untagged-only). It is the escape hatch —
#     if the compat segment is ever misconfigured, a laptop on ether1 still reaches the router.
#     An escape port sitting in compat would go down *with* compat, which is not an escape.
#   * the LAN address leaves `ether2` (a bridge slave, nowhere for a router address) and lands on
#     an explicit compat VLAN interface, so the bridge's VLAN table says who owns it. Same address,
#     same prefix — clients see nothing.
#   * both segments appear in the bridge VLAN table with the bridge itself as the tagged (CPU)
#     member. This is the part that locks people out when it is missing: `vlan-filtering=yes`
#     without a VLAN entry for the segment carrying your own management address means the router
#     stops answering on it.
#
# Rollback: set `vlan_filtering = false` in bridge.tf, or restore the pre-change backup. The address
# can stay on the VLAN interface — with filtering off it behaves exactly as before.
#
# Acceptance test after apply: every bridge port still reads hw=yes (bonds included elsewhere), a LAN
# client still reaches the internet, and a laptop on ether1 reaches 172.16.10.1.

# ---------------------------------------------------------------------------
# The compat segment's L3 endpoint. Temporary by design: when the last device has moved off
# 172.16.100.0/24, this interface, its address and the compat entry in the bridge VLAN table are
# deleted together, and nothing else has to change.
# ---------------------------------------------------------------------------
resource "routeros_interface_vlan" "compat" {
  interface = var.bridge_interface
  name      = "vlan1-compat"
  vlan_id   = 1
  comment   = "${local.managed_by} (${var.router_name}) — drains last"
}

# ---------------------------------------------------------------------------
# The LAN address, adopted from `ether2` and moved onto the compat VLAN interface.
# id `*1` is its RouterOS internal id: /ip/address print shows it next to 172.16.100.1/24.
# ---------------------------------------------------------------------------
import {
  to = routeros_ip_address.lan
  id = "*1"
}

resource "routeros_ip_address" "lan" {
  address   = "172.16.100.1/24"
  interface = routeros_interface_vlan.compat.name
  comment   = "defconf"
  network   = "172.16.100.0"
  disabled  = false
  vrf       = "main"
}

# ---------------------------------------------------------------------------
# The bridge VLAN table. `tagged` names the bridge itself: that is the CPU's membership, which is
# what lets the router keep L3 on the segment. The untagged members are the ports already carrying
# that segment today — unchanged from the device's point of view.
# ---------------------------------------------------------------------------
resource "routeros_interface_bridge_vlan" "compat" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["1"]
  tagged   = [routeros_interface_bridge.bridge.name]
  untagged = ["ether2", "ether3", "ether4", "ether6", "ether7", "ether8", "sfp-sfpplus1"]
  comment  = "compat — everything not yet migrated; deliberately does not include ether1"
}

resource "routeros_interface_bridge_vlan" "mgmt" {
  bridge   = routeros_interface_bridge.bridge.name
  vlan_ids = ["10"]
  tagged   = [routeros_interface_bridge.bridge.name]
  untagged = ["ether1"]
  comment  = "mgmt — the escape port's segment; reachable whatever compat does"
}
