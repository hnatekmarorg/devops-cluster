# The WAN — adopted, then taken out of the LAN bridge
#
# Why this file exists
# --------------------
# Measured 2026-09-14: the PPPoE client is bound to `bridge`, not to a port:
#
#   /interface/pppoe-client print
#     name      interface   add-default-route   use-peer-dns
#     t-mobile  bridge      true                true
#
# So the WAN shares the flat LAN's L2 domain. The bridge floods the client's PPPoE
# discovery frames to every LAN port, ISP-side MACs are learned on `ether5` in the LAN
# bridge's host table, and any LAN device can see — and in principle speak to — the ISP's
# concentrator. `ether5` is the ISP uplink (confirmed by counters: 20 MB downloaded from a
# LAN host moved ether5 rx +24.76 MiB and ether4 tx +24.64 MiB, every other port zero).
#
# It is also the one port the VLAN carve must not touch: a WAN sitting inside a LAN bridge
# gets a class the first time someone applies a port table mechanically, and the internet
# moves with it. Fixing it is what makes "the WAN is never in a LAN VLAN" a property.
#
# Three waves, each its own commit, so the risky step is isolated
# -------------------------------------------------------------
#   1  import the two objects as they are      → expect: 2 to import, 0 to change
#   2a move the PPPoE client onto ether5       → expect: 1 to change  (session re-establishes)
#   2b take ether5 out of the bridge           → expect: 1 to destroy  (no WAN interruption)
#
# 2a first, deliberately: once the session rides the port directly, removing the bridge
# membership cannot disturb the WAN at all.

# ---------------------------------------------------------------------------
# Wave 1 — adoption only. Nothing here changes behaviour; the plan after this
# commit is "2 to import, 0 to add, 0 to change, 0 to destroy", which is the
# proof that the baseline is faithful. Delete these import blocks once the
# first apply has run (they become no-ops, but they are noise afterwards).
#
# The bridge-port id is RouterOS' internal id at the time of writing; if it no
# longer matches, re-read it: /interface/bridge/port print
# ---------------------------------------------------------------------------
import {
  to = routeros_interface_pppoe_client.t_mobile
  id = "t-mobile"
}

import {
  to = routeros_interface_bridge_port.ether5
  id = "*3"
}

resource "routeros_interface_pppoe_client" "t_mobile" {
  name              = "t-mobile"
  interface         = "bridge" # wave 2a moves this to ether5
  add_default_route = true
  use_peer_dns      = true
  disabled          = false

  # Both credential attributes are deliberately outside management:
  #   * the provider cannot read the password back — it reports `sensitive value`
  #     in state and null in a generated config, so without this an apply would
  #     blank it and take the PPPoE session down;
  #   * the account name is returned as a plain string, and it is the ISP's
  #     identifier, not ours to manage.
  # The ISP credentials stay a device-side bootstrap fact.
  lifecycle {
    ignore_changes = [password, user]
  }
}

resource "routeros_interface_bridge_port" "ether5" {
  bridge    = "bridge"
  interface = "ether5"
  pvid      = 1

  # Declared because it exists on the device — a baseline that omits it would
  # plan a change on adoption (`defconf`, RouterOS' default-config marker).
  comment = "defconf"
}
