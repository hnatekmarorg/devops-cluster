# Stage 2 — a DHCP scope per class, and the fixed addresses the estate depends on.
#
# Additive: no device is attached to these VLANs yet, so this changes nothing on the wire. It is
# the *pre-work* for moving devices — a port cannot move to a segment that cannot address it.
#
# Two rules this file encodes, both learned the hard way tonight:
#
#   1. **Pool ranges deliberately avoid `.100–.199`.** That band is where the harness's dependants
#      live, and their addresses are load-bearing: the inference fleet is *addressed by IP* in
#      `lmproxy` on the Hermes host, so a Spark that re-addresses without its suffix takes the
#      agent's inference path with it. Keeping the band free, plus explicit static leases, means
#      a device moving into `lab` keeps the number everyone already knows — only the subnet
#      changes. Widening a pool into that band would quietly reintroduce the hazard.
#
#   2. **No `iot` scope.** The WiFi segment hangs off the Deco BE22, which may serve DHCP itself;
#      two servers on one segment is a conflict, not a convenience. Whether the Deco or the router
#      addresses the WiFi segment is a question for the step that moves it.
#
# The compat scope (172.16.100.0/24, pool `public`) is left unmanaged and untouched — it drains
# last, and adopting it buys nothing while it is on its way out.

locals {
  dhcp_scopes = {
    mgmt = {
      subnet    = "172.16.0.0/20"
      gateway   = "172.16.10.1"
      interface = "vlan10-mgmt"
      server    = "dhcp-mgmt"
      pool      = "dhcp-pool-mgmt"
      # .1 router, .125 probe, .10x gear — the pool starts clear of all of it.
      ranges = ["172.16.10.200-172.16.10.250"]
    }
    lab = {
      subnet    = "172.16.16.0/20"
      gateway   = "172.16.30.1"
      interface = "vlan30-lab"
      server    = "dhcp-lab"
      pool      = "dhcp-pool-lab"
      # Sits either side of the reserved band on purpose: see rule 1 above.
      ranges = ["172.16.30.20-172.16.30.99", "172.16.30.200-172.16.30.250"]
    }
    srv = {
      subnet    = "172.16.32.0/19"
      gateway   = "172.16.40.1"
      interface = "vlan40-srv"
      server    = "dhcp-srv"
      pool      = "dhcp-pool-srv"
      # The service-VIP block (172.16.48.0/20) is not in this range and must never be.
      ranges = ["172.16.40.20-172.16.40.99", "172.16.40.200-172.16.40.250"]
    }
  }

  # Fixed addresses for the hosts the agent's own path depends on. MACs measured from the live
  # lease table (2026-09-14). These are the reason a device can move segments without anything
  # that talks to it needing to learn a new number — only a new subnet.
  # `class` indexes the DHCP server resource rather than naming it as a string: a literal name
  # creates no dependency edge, so the leases were attempted before their server existed and
  # RouterOS answered "input does not match any value of server". A reference makes Terraform
  # order them, which is the only thing that was wrong with them.
  dhcp_reservations = {
    "spark1"    = { mac = "30:C5:99:3E:37:65", address = "172.16.30.136", class = "lab" }
    "spark2"    = { mac = "30:C5:99:3E:3F:DE", address = "172.16.30.137", class = "lab" }
    "spark3"    = { mac = "30:C5:99:3F:25:2E", address = "172.16.30.112", class = "lab" }
    "spark4"    = { mac = "30:C5:99:3F:A3:8B", address = "172.16.30.110", class = "lab" }
    "inference" = { mac = "BC:24:11:5D:F4:C7", address = "172.16.30.189", class = "lab" }
  }
}

resource "routeros_ip_pool" "class" {
  for_each = local.dhcp_scopes

  name    = each.value.pool
  ranges  = each.value.ranges
  comment = "${local.managed_by} (${var.router_name}) — ${each.key}"
}

resource "routeros_ip_dhcp_server" "class" {
  for_each = local.dhcp_scopes

  name         = each.value.server
  interface    = each.value.interface
  address_pool = routeros_ip_pool.class[each.key].name
  lease_time   = "10m" # matches the compat scope: fast propagation in both directions

  # The device's own default, declared rather than omitted: the provider reads it back and plans
  # `-> null` when the config is silent, i.e. it would *clear* a setting the device wants set.
  # Same lesson as `vrf` — adopting an object means declaring what it already has.
  dynamic_lease_identifiers = "client-mac,client-id"
  disabled                  = false
  comment                   = "${local.managed_by} (${var.router_name}) — ${each.key}"
}

resource "routeros_ip_dhcp_server_network" "class" {
  for_each = local.dhcp_scopes

  address    = each.value.subnet
  gateway    = each.value.gateway
  dns_server = ["8.8.8.8"] # the compat scope's convention; the router's own resolver is still off
  comment    = "${local.managed_by} (${var.router_name}) — ${each.key}"
}

# Static leases: the addresses the agent's inference path is written against. Declared here so
# they exist before anything moves, rather than being discovered as a broken endpoint later.
resource "routeros_ip_dhcp_server_lease" "reserved" {
  for_each = local.dhcp_reservations

  address     = each.value.address
  mac_address = each.value.mac
  server      = routeros_ip_dhcp_server.class[each.value.class].name
  comment     = "${local.managed_by} — fixed identity: the Hermes host reaches this by IP"
}
