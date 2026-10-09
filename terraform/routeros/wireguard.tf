# WireGuard — remote access, tunnel terminated on the router.
#
# WHAT THIS FILE IS, AND WHAT IT DELIBERATELY IS NOT
# ----------------
# The router authenticates a *device* (a peer key). Who a person is, and what that person may then use,
# is a different question asked above this layer (Keycloak + forward-auth per app) — the two are kept
# apart on purpose, so there is no OIDC here, no per-user peer, and nothing in this file has to change
# when the identity layer does. `AllowedIPs` on a client is **routing**, not policy: what a tunnel
# client may reach is decided by the firewall matrix, in one place.
#
# WHY IT IS ON THE ROUTER, AND WHY NOW
# ----------------
# The estate's inbound path is already gone: all ten `dst-nat` port-forwards still point at compat
# addresses that no longer answer (measured 2026-09-25 — the edge proxy, the ingress VIP, the k8s API
# and the jumphost among them), and the overlay kept as the break-glass (headscale) no longer exists.
# So this is not replacing a working path, it is restoring the only one. The useful consequence: nothing
# depends on the tunnel yet, so rollback is "disable the peers, then the accepts" and there is no
# cut-over window to schedule.
#
# THE SHAPE, AND WHY IT IS TWO BLOCKS
# ----------------
# The zone (`vlan60-vpn`, `172.16.96.0/20`) already exists with the class's policy and is where a VM
# tagged into VLAN 60 lives. The tunnel's own **peer transport** keeps a separate block —
# `172.16.112.0/20`, reserved for exactly this in `main.tf` — so peers never have to share a subnet with
# the zone across two interfaces, which RouterOS dislikes. Both blocks are inside the `vpn-nets` address
# list, so a tunnel client is `vpn`-class **by construction**, arriving by a different transport than a
# VLAN-tagged guest and judged by the same rows. Peers take /32s; the interface owns the transport
# block's `.1`, which is what creates the connected route to them (no static route needed).
#
# THE ROW THIS TUNNEL GETS — AND THE PART OF IT THAT IS NOT ENFORCED YET
# ----------------
# `docs/firewall-matrix.md`: **vpn → mgmt scoped · srv on service ports · lab scoped · iot ✗ ·
# internet ✓**. The forward chain has no catch-all, so a class row's ✓ cells are satisfied by
# *fall-through*: today a tunnel client reaches more than that sentence describes. This is stated rather
# than left implied, because it is the one thing a reader could reasonably assume the opposite of. Q21's
# enforcement order is iot → lab → srv → mgmt (compat last) and `vpn` is not in it yet; the accept-list
# that enforces the row is its own reviewed step, and it needs the service-port list that the `lab → srv`
# measurement produces.
#
# The router itself is the exception, and it IS scoped here: traffic addressed to the box is judged by
# the *input* chain, and this file adds exactly what a tunnel needs there and nothing more.
#
# PLACEMENT — THE PART NO PLAN CAN SEE
# ----------------
# RouterOS has no rule priority: order *is* the priority, first match wins, and the provider models no
# position — so an accept inserted above them changes the effective policy with no diff anywhere. Every
# input rule below is inserted with `place_before`, and for the defconf rule that anchor's id comes from
# the provider's generic `routeros_ip_firewall` data source, because that rule is the device's and not
# ours. Two facts make the anchors load-bearing:
#
#   * the defconf `drop all not coming from LAN` (`in-interface-list=!LAN`) is the first judgement on
#     anything addressed to the router that did not arrive on a class VLAN. This file contains the
#     estate's **first WAN input accept**, so it is also the first rule that has to sit *above* that
#     drop rather than being appended below it;
#   * the WireGuard interface is deliberately **not** added to the `LAN` interface list. That membership
#     is the crutch the class default-denies exist to replace, and a tunnel client should reach the
#     router only where the policy says so — which means the *decapsulated* traffic to the router's own
#     addresses (`in-interface=vpn`, not in `LAN`) meets the same defconf drop. Hence the DNS accepts
#     below are anchored above it too, not appended.
#
# A rule created *with* `place_before` costs nothing; putting `place_before` on an existing rule is what
# forces its replacement (see `stage3-firewall.tf`). Nothing here edits a live rule.
#
# `scripts/matrix-order-check.py` asserts the resulting order against the live device, because this
# ordering is invisible to `plan` and a wrong order fails *closed* in the one direction that matters
# least (the tunnel simply does not come up) and *open* in the other (an accept lands above a drop it
# should not). The comment prefixes below are load-bearing for that check.
#
# THE ENDPOINT IS PUBLISHED AS A NAME, AND THE NAME IS ITSELF A POLICY OBJECT
# ----------------
# `dns.tf` answers `vpn.hnatekmar.dev` internally (`172.16.96.1`); the *public* answer is the WAN address
# and is not in this repository yet (Phase 4 owns Cloudflare-as-code). Until that record exists the name
# resolves through the public `*.hnatekmar.dev` wildcard to the **dead** ingress VIP, so a profile minted
# before it exists points at nothing. See `docs/dns.md`.
#
# One plumbing consequence worth stating, because it looks like a bug: a client at home sits in `iot`,
# and `iot` is handed a *public* resolver (`8.8.8.8`) by design — so it resolves the endpoint to the WAN
# address rather than to the internal one, and the packet arrives on the bridge addressed to the
# router's own WAN address. There is no `dstnat` in that path, so no NAT hairpin is involved; it is
# judged by the input chain, which is why `wireguard_iot_endpoint` is a class accept and not scoped to a
# destination address.

locals {
  wireguard = {
    name        = "vpn"
    address     = "172.16.112.1/20" # the transport block's .1 — the route to the peers
    listen_port = 51820
  }

  # One entry per device, so revoking a device is deleting its block. The public key is contributed BY
  # the device (`wg genkey | tee private.key | wg pubkey`): it is public by definition, so it may live
  # here, while the private half never leaves the device — not the vault, not this repository, not a
  # transcript. Generating client keys centrally is machinery that only pays off when many clients are
  # provisioned by somebody who never touches the device; at two devices it buys custody problems and
  # nothing else.
  #
  # **Empty means "no peer yet".** The endpoint is then published but inert — WireGuard answers nothing
  # to a key it does not know — and no client can complete a handshake until the key is filled in.
  wireguard_peers = {
    laptop = { public_key = "", address = "172.16.112.10/32" }
    phone  = { public_key = "", address = "172.16.112.11/32" }
  }
}

resource "routeros_interface_wireguard" "vpn" {
  name        = local.wireguard.name
  listen_port = local.wireguard.listen_port

  # `private_key` is optional + **computed** + **sensitive**, and both CI identities carry
  # `!sensitive` (`ci-ro`, `iac` — read off the device, not assumed), so a key the *device* generates
  # can never be read back: replacing this resource would silently change the server key, kill every
  # client profile at its next handshake, and leave nothing anywhere able to restore it. Declaring it
  # makes recreation idempotent.
  #
  # The trade, stated: the value then also lives in Terraform state (MinIO — the same trust domain as
  # the repo's other secrets, never in git). It arrives as `TF_VAR_wg_server_private_key` from an
  # **environment** secret on the `routeros-production` environment, not a repository secret — a
  # repository secret is readable by any job a same-repo branch can trigger, which is the property Q14
  # keeps the write identity away from.
  #
  # Empty (how a pull request plans it) resolves to `null` = "not managed here", so no plan needs the
  # value. The bootstrap step that must exist before the first apply is in the pull request and
  # `terraform/README.md`.
  private_key = var.wg_server_private_key == "" ? null : var.wg_server_private_key

  comment = "${local.managed_by} (${var.router_name})"
}

resource "routeros_ip_address" "wireguard" {
  address   = local.wireguard.address
  interface = routeros_interface_wireguard.vpn.name
  comment   = "${local.managed_by} (${var.router_name})"
}

resource "routeros_interface_wireguard_peer" "device" {
  for_each = { for name, peer in local.wireguard_peers : name => peer if peer.public_key != "" }

  interface  = routeros_interface_wireguard.vpn.name
  public_key = each.value.public_key
  # That client's own /32 and nothing wider: the router should route a peer's traffic, not hand it the
  # block its neighbours live in.
  allowed_address = [each.value.address]
  # The router answers handshakes; it never chases an endpoint. Correct posture for a client behind
  # carrier NAT, which is where a phone lives.
  is_responder = true
  comment      = "${local.managed_by} — ${each.key}"
}

# The defconf drop, read rather than assumed. `place_before` takes a rule id, and this rule is the
# device's own — adopting the defconf rules is a separate piece of work (the endgame Q22 records), so
# here the id is looked up by the comment the device reports. The filter is an exact match, so a
# renamed or absent rule fails the **plan** loudly instead of quietly appending the accepts below the
# drop they must precede.
data "routeros_ip_firewall" "input_chain" {
  rules {
    filter = {
      chain   = "input"
      comment = "defconf: drop all not coming from LAN"
    }
  }
}

# The tunnel endpoint, from the internet. `in_interface_list = "WAN"` narrows it to the path it is for
# (and keeps the guardian's "no blanket accept" assertion true); the WAN list holds `t-mobile`.
resource "routeros_ip_firewall_filter" "wireguard_wan" {
  chain  = "input"
  action = "accept"
  # Above the defconf drop — the whole point of this rule. See the header.
  place_before      = data.routeros_ip_firewall.input_chain.rules[0].id
  protocol          = "udp"
  in_interface_list = "WAN"
  dst_port          = tostring(local.wireguard.listen_port)
  comment           = "wireguard: the tunnel endpoint on the WAN — firewall-matrix.md"
}

# A client at home sits in `iot`, whose row is "internet ✓ only" and whose router access is a
# default-deny — so without this accept the device that most needs the tunnel is the one that cannot
# bring it up, while its config looks perfectly correct. The precedent is the DHCP accept sitting beside
# that drop ("the one router service a segment cannot live without").
#
# Not destination-scoped, on purpose: the input chain already means "addressed to the router", and `iot`
# is handed a public resolver, so this client resolves the endpoint to the WAN address and what arrives
# is a packet to the router's own WAN address over the bridge. No `dstnat`, so no hairpin.
resource "routeros_ip_firewall_filter" "wireguard_iot_endpoint" {
  chain            = "input"
  action           = "accept"
  place_before     = routeros_ip_firewall_filter.iot_router_deny.id
  protocol         = "udp"
  src_address_list = "iot-nets"
  dst_port         = tostring(local.wireguard.listen_port)
  comment          = "wireguard: the WiFi class may reach the tunnel endpoint — its way back in — firewall-matrix.md"
}

# The tunnel's own traffic to the router, scoped to one service: DNS.
#
# The client's resolver is the router's address in its class (`172.16.96.1`, the `vlan60-vpn` gateway),
# which is the same rule every DHCP scope follows — a resolver the client's class denies would give it
# an IP path and no names, which reads as a broken tunnel. Anchored above the same defconf drop: the
# WireGuard interface is not in `LAN`, so decapsulated traffic never passes that drop by fall-through.
#
# Two rules and not one, because RouterOS refuses a port without a protocol and then refuses a *list* in
# the protocol field (`protocol` holds one name or number, while `dst_port` takes a list). Both are
# needed: a filtered resolver falls back to TCP on a truncated answer.
#
# NTP is deliberately absent: a client that is not the reader takes time from whatever network it is on,
# and the router serving time to the *zone's* DHCP scope is a separate question (`dhcp.tf`).
resource "routeros_ip_firewall_filter" "wireguard_dns" {
  for_each = toset(["tcp", "udp"])

  chain  = "input"
  action = "accept"
  # Above the defconf drop, like the endpoint accept and for the same reason.
  place_before     = data.routeros_ip_firewall.input_chain.rules[0].id
  protocol         = each.value
  src_address_list = "vpn-nets"
  dst_port         = "53"
  comment          = "wireguard: the tunnel's resolver over ${upper(each.value)} — the class's DNS row — firewall-matrix.md"
}

# ---------------------------------------------------------------------------
# The profile each device carries — here so the contract sits next to the code that defines its inputs.
#
#   [Interface]
#   PrivateKey = <generated on the device; never leaves it>
#   Address    = 172.16.112.10/32        # .11 for the phone — its own entry in `wireguard_peers`
#   DNS        = 172.16.96.1             # the router's address in the vpn class (the DNS accepts above)
#   MTU        = 1420                    # the WAN is PPPoE (1492); leave room for the WG header
#
#   [Peer]
#   PublicKey           = <the router's public key, read off the device>
#   AllowedIPs          = 172.16.0.0/12  # split tunnel: the estate's private aggregate, and nothing else
#   Endpoint            = vpn.hnatekmar.dev:51820
#   PersistentKeepalive = 25             # a roaming client behind carrier NAT stays reachable
#
# Split tunnel is *routing*: it decides what the device sends down the tunnel, while what is **accepted**
# stays on the router's class rules — the policy is never copied into a client config, because a second
# copy is the thing that drifts. What it means day to day, in plain terms: internal names and services
# work; everything else uses whatever link the device is on, at that link's speed; the device is *not*
# "at home" for the wider internet, so its public address while browsing is the local one; and if the
# home link drops, estate traffic stops rather than the whole internet.
#
# A full tunnel is a per-peer choice (one line, `AllowedIPs = 0.0.0.0/0`) and if it is ever taken, that
# profile must disable IPv6 or v6 traffic escapes around the tunnel.
# ---------------------------------------------------------------------------
