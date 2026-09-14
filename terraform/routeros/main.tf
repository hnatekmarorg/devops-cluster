# ---------------------------------------------------------------------------
# STAGE 1 — additive groundwork only, zero behavioural change:
#   * new VLAN interfaces (no ports assigned; inert until a later stage makes
#     the bridge VLAN-aware)
#   * gateway addresses on those VLANs
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

  # VLAN numbering and sizing: decision register Q2 (defaults taken as agreed).
  vlans = {
    mgmt    = { vlan_id = 10, name = "vlan10-mgmt", cidr = "172.16.10.0/24" }
    trusted = { vlan_id = 20, name = "vlan20-trusted", cidr = "172.16.20.0/24" }
    lab     = { vlan_id = 30, name = "vlan30-lab", cidr = "172.16.30.0/24" }
    srv     = { vlan_id = 40, name = "vlan40-srv", cidr = "172.16.40.0/24" }
    guest   = { vlan_id = 50, name = "vlan50-guest", cidr = "172.16.50.0/24" }
  }
  # No VLAN for the VPN zone: WireGuard clients live on the wireguard
  # interface's own subnet (172.16.60.0/24, stage 3).

  ai_compute = [for ip in split(",", var.ai_compute_hosts) : trimspace(ip) if trimspace(ip) != ""]

  # Address-list *names* are the interface the future firewall matrix is written
  # against. Creating them now costs nothing and lets the policy be reviewed
  # separately from the objects it references.
  address_lists = {
    "lan-nets"       = ["172.16.100.0/24"]
    "mgmt-nets"      = ["172.16.10.0/24", "172.16.60.0/24"]
    "vpn-clients"    = ["172.16.60.0/24"]
    "trusted-nets"   = ["172.16.20.0/24"]
    "lab-nets"       = ["172.16.30.0/24"]
    "srv-nets"       = ["172.16.40.0/24"]
    "guest-nets"     = ["172.16.50.0/24"]
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

  # .1 of each VLAN: the gateway address the firewall matrix and DHCP scopes
  # will point at once the bridge becomes VLAN-aware.
  address   = format("%s/%s", cidrhost(each.value.cidr, 1), split("/", each.value.cidr)[1])
  interface = routeros_interface_vlan.vlan[each.key].name
  comment   = "${local.managed_by} (${var.router_name})"
}

resource "routeros_ip_firewall_addr_list" "entries" {
  for_each = { for entry in local.address_list_entries : "${entry.list}|${entry.address}" => entry }

  list    = each.value.list
  address = each.value.address
  comment = local.managed_by
}
