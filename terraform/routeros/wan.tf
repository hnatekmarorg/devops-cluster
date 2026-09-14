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
# Two stages, each its own commit:
#   1  adopt the objects as they are   → imports only, 0 to change
#   2  the change itself (below)       → one change, then the port leaves the bridge

# ---------------------------------------------------------------------------
# Wave 2 — the WAN leaves the LAN bridge: the PPPoE client moves onto the ISP's own port
# (`ether5`), and that port stops being a bridge member. Until this lands, the bridge carries
# the session's frames to `ether5` — and the ISP's frames into every LAN port with them.
#
# Order is forced by the device: RouterOS will not bind a PPPoE client to a bridge slave
# (`invalid`, "Client is on slave interface"), so the port leaves the bridge first and the
# client binds to it after. Rollback is the same order reversed.
# ---------------------------------------------------------------------------
import {
  to = routeros_interface_pppoe_client.t_mobile
  id = "t-mobile"
}

resource "routeros_interface_pppoe_client" "t_mobile" {
  name              = "t-mobile"
  interface         = "ether5" # wave 2a: off the bridge, onto the ISP uplink's own port
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

