# ---------------------------------------------------------------------------
# STAGE 1 — additive groundwork only, zero behavioural change:
#   * new VLAN interfaces (no ports assigned; inert until a later stage makes
#     the bridge VLAN-aware)
#   * gateway addresses on those VLANs (the .1 of each host space, inside its block)
#   * firewall address-lists (not referenced by any rule yet)
# Nothing that already exists on the router is modified or deleted. Existing
# objects (bridge, addresses, DHCP, firewall rules) can be adopted later without
# recreation — terraform-routeros supports `tofu import`, and OpenTofu >= 1.5
# understands `import {}` blocks — which is what Phase 2 of the overhaul plan
# does.
#
# Approval gate for the next stage (from the plan): the bridge is NOT touched
# here. No `vlan-filtering`, no tagged ports, no DHCP servers, no firewall rules.
# ---------------------------------------------------------------------------

locals {
  managed_by = "managed-by:opentofu+gha devops-cluster"

  # Block plan — 2026-09-14, agreed with Martin: every class owns an *aligned block* inside
  # 172.16.0.0/16, sized so that service-VIP space is never the constraint again. The host
  # space keeps the familiar third octet (.10/.30/.40/.70) so every diagram and table written
  # so far stays readable, while the blocks are what the router aggregates and what the
  # firewall zones are cut from.
  #
  #   172.16.0.0/20     0 –  15.255   mgmt    host space 172.16.10.0/24
  #   172.16.16.0/20    16 –  31.255   lab     host space 172.16.30.0/24
  #   172.16.32.0/19    32 –  63.255   srv     host space 172.16.40.0/24
  #                                             VIP space 172.16.48.0/20  ← MetalLB pool
  #   172.16.64.0/20    64 –  79.255   iot     host space 172.16.70.0/24
  #   172.16.96.0/20    96 – 111.255   vpn     host space 172.16.96.0/24  (zone, not a VLAN)
  #   172.16.100.0/24                  compat  the flat LAN — drains last, deliberately
  #                                             outside the blocks so it can disappear cleanly
  #   172.16.20.0/24 / 172.16.50.0/24          retired classes (trusted, guest): numbers stay
  #                                             unused rather than recycled
  #
  # Service VIPs: the MetalLB pool is 172.16.48.1 - 172.16.63.254 (Martin, 2026-09-14), inside
  # srv's /19 — see the gateway comment above for why that placement is the whole point: pool
  # and announcing nodes end up in one subnet, so L2 announcement works and no routing protocol
  # is needed. If the single-announcer hotspot of L2 ever becomes a real constraint, BGP remains
  # the upgrade path and this range works there unchanged (the router would route the /20 to the
  # nodes) — but that is an optimisation to reach for later, not a prerequisite.
  #
  # IPv6 is deliberately out of scope for this overhaul (2026-09-14): the estate has enough
  # moving parts without a second address family. The blocks are aligned power-of-two
  # aggregates so a later v6 plan can mirror them one-for-one rather than re-cut the estate,
  # and names remain the interface everywhere so re-addressing is not re-architecting.
  vlans = {
    mgmt = { vlan_id = 10, name = "vlan10-mgmt", subnet = "172.16.0.0/20", gateway = "172.16.10.1/20" }
    lab  = { vlan_id = 30, name = "vlan30-lab", subnet = "172.16.16.0/20", gateway = "172.16.30.1/20" }
    srv  = { vlan_id = 40, name = "vlan40-srv", subnet = "172.16.32.0/19", gateway = "172.16.40.1/19" }
    iot  = { vlan_id = 70, name = "vlan70-iot", subnet = "172.16.64.0/20", gateway = "172.16.70.1/20" }
  }
  # No VLAN interface for these, on purpose:
  #   * VLAN 999 — the unrouted parking VID. It exists so an end-state trunk can carry a tag
  #     that reaches nothing; it is a bridge-VLAN entry (`/interface/bridge/vlan`), never an
  #     interface with an address, so it is created in the filtering stage, not here.
  #   * the VPN zone (172.16.96.0/24) — WireGuard clients arrive on the tunnel interface, not
  #     on a switch port, so it is a *zone* without a VID. The 60 number stays unused.

  ai_compute = [for ip in split(",", var.ai_compute_hosts) : trimspace(ip) if trimspace(ip) != ""]

  # Address-list *names* are the interface the future firewall matrix is written against.
  # Blocks, not host subnets: a rule should not need editing because a host moved within its
  # own class. Retired classes (trusted, guest) are not listed — nothing will ever be in them.
  address_lists = {
    "lan-nets"       = ["172.16.100.0/24"]
    "mgmt-nets"      = ["172.16.0.0/20"]
    "vpn-nets"       = ["172.16.96.0/20"]
    "lab-nets"       = ["172.16.16.0/20"]
    "srv-nets"       = ["172.16.32.0/19"]
    "iot-nets"       = ["172.16.64.0/20"]
    "svc-vips"       = ["172.16.48.0/20"]
    "ai-compute"     = local.ai_compute
    "wan-restricted" = local.ai_compute
  }

  address_list_entries = flatten([
    for list_name, addresses in local.address_lists : [
      for address in addresses : {
        list    = list_name
        address = address
      }
    ]
  ])
}

resource "routeros_interface_vlan" "vlan" {
  for_each = local.vlans

  interface = var.bridge_interface
  name      = each.value.name
  vlan_id   = each.value.vlan_id
  comment   = "${local.managed_by} (${var.router_name})"
}

resource "routeros_ip_address" "vlan_gateway" {
  for_each = local.vlans

  # One subnet per class, sized by its block: the interface carries the *class* prefix, with
  # its address at the .1 of the host area. That is what makes the address space allocatable
  # rather than just documented — the MetalLB pool (172.16.48.1-172.16.63.254) sits inside
  # srv's /19 as a sibling of the host addresses, so a node in srv and a VIP in the pool are
  # in the same subnet and L2 announcement works.
  address   = each.value.gateway
  interface = routeros_interface_vlan.vlan[each.key].name
  comment   = "${local.managed_by} (${var.router_name})"
}

resource "routeros_ip_firewall_addr_list" "entries" {
  for_each = { for entry in local.address_list_entries : "${entry.list}|${entry.address}" => entry }

  list    = each.value.list
  address = each.value.address
  comment = local.managed_by
}
