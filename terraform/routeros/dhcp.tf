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
#   2. **`iot` gets a scope — for the host we own, not for the WiFi.** The TV-isolation gateway is
#      moving into that segment by cable and must be addressable there (`.70.125` keeps its suffix, the
#      same rule as everywhere else). Whether the Deco BE22 serves its *own* clients or expects this
#      router to is still open — two servers on one segment is a conflict, not a convenience — so the
#      pool stays modest and that question is answered when the WiFi segment actually moves.
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
    iot = {
      subnet    = "172.16.64.0/20"
      gateway   = "172.16.70.1"
      interface = "vlan70-iot"
      server    = "dhcp-iot"
      pool      = "dhcp-pool-iot"
      # Same shape as lab, and for the same reason (rule 1): the host space is the `.70` block of the
      # /20, and the pool stays clear of `.100–.199` where the fixed identities live.
      ranges = ["172.16.70.20-172.16.70.99", "172.16.70.200-172.16.70.250"]
    }
  }

  # Fixed addresses for the hosts the estate's own paths depend on — including the out-of-band plane.
  # MACs measured from the live tables. These are the reason a device can move segments without
  # anything that talks to it needing to learn a new number — only a new subnet.
  #
  # `balteus-ipmi` keeps its `.46` suffix across segments, like the Sparks keep theirs: the BMC is
  # configured with a static address (measured 2026-09-15 — it has no lease and `.46` sits outside
  # the unmanaged compat pool), so this reservation is the *documented claim* on `172.16.10.46` in
  # mgmt and the address it takes if it is ever switched to DHCP. `ether7` is its access port.
  #
  # `class` indexes the DHCP server resource rather than naming it as a string: a literal name
  # creates no dependency edge, so the leases were attempted before their server existed and
  # RouterOS answered "input does not match any value of server". A reference makes Terraform
  # order them, which is the only thing that was wrong with them.
  dhcp_reservations = {
    "spark1"       = { mac = "30:C5:99:3E:37:65", address = "172.16.30.136", class = "lab" }
    "spark2"       = { mac = "30:C5:99:3E:3F:DE", address = "172.16.30.137", class = "lab" }
    "spark3"       = { mac = "30:C5:99:3F:25:2E", address = "172.16.30.112", class = "lab" }
    "spark4"       = { mac = "30:C5:99:3F:A3:8B", address = "172.16.30.110", class = "lab" }
    "inference"    = { mac = "BC:24:11:5D:F4:C7", address = "172.16.30.189", class = "lab" }
    "balteus-ipmi" = { mac = "3C:EC:EF:73:09:9D", address = "172.16.10.46", class = "mgmt" }

    # The dedicated CI runner (a ZimaBoard, plugged in by hand). It is on a *compat* port today
    # (`.100.126`) and takes this address as soon as it hangs off a mgmt access port — the router's
    # `ether1`, which is already prepared for exactly this (pvid 10, admit-only-untagged). Mgmt class
    # because it holds the device write credentials (Q27/Q29).
    "runner" = { mac = "00:E0:4C:2A:36:AC", address = "172.16.10.140", class = "mgmt" }

    # Re-classed to mgmt on 2026-09-16: an operator host — it holds the vault and the estate's WebUI,
    # and it administers other hosts — sitting on a mgmt access port (measured: tagged there, it took a
    # mgmt pool address). Suffix preserved, the way the Sparks and the BMC keep theirs: `.10.180`.
    "personal-hermes" = { mac = "BC:24:11:AA:F1:B6", address = "172.16.10.180", class = "mgmt" }

    # srv: the keepers. Each keeps its compat suffix, so a guest that is tagged into srv comes up at the
    # address its record already names — zero address changes, and nothing that references it by IP has
    # to change either. Suffix preservation outranks the `.100-.199` band here: a reservation excludes
    # the address from dynamic assignment wherever it sits.
    "truenas"            = { mac = "BC:24:11:B8:73:CF", address = "172.16.40.148", class = "srv" }
    "gitea"              = { mac = "BC:24:11:DE:C2:B9", address = "172.16.40.124", class = "srv" }
    "github-dind"        = { mac = "BC:24:11:09:29:12", address = "172.16.40.145", class = "srv" }
    "coder"              = { mac = "BC:24:11:15:09:81", address = "172.16.40.210", class = "srv" }
    "kubernetes-sandbox" = { mac = "BC:24:11:34:A3:9C", address = "172.16.40.111", class = "srv" }
    "stories-hermes"     = { mac = "BC:24:11:95:D1:9A", address = "172.16.40.188", class = "srv" }
    "sister-hermes"      = { mac = "BC:24:11:58:A8:1E", address = "172.16.40.203", class = "srv" }
    # The edge/identity/lmproxy host. `.100.30` is configured *statically on the box*, so this
    # reservation is the documented claim on the address (the shape the BMC's `.46` has) and only takes
    # effect if the box is switched to DHCP. Suffix preserved: `.40.30`.
    "proxy" = { mac = "BC:24:11:75:DD:2B", address = "172.16.40.30", class = "srv" }
    # Infrastructure on a pool lease is a fragility: the spine's management address must not depend
    # on pool churn. It moved to mgmt on 2026-09-15 and keeps the address it landed on (`.201`) rather
    # than being moved again for suffix symmetry — one address change per device is enough.
    "crs804" = { mac = "D0:EA:11:02:70:5A", address = "172.16.10.201", class = "mgmt" }
    # The TV-isolation gateway again, in the class it is moving to: `.125` keeps its suffix the way it
    # did in compat (`172.16.100.125`, reserved in the unmanaged compat scope) and in mgmt. Different
    # subnet, same identity — so the weekly digest and the TV harness keep working from wherever the box
    # sits, and the iot segment can be observed from a device inside it.
    "probe-iot" = { mac = "00:E0:4C:2A:2E:C6", address = "172.16.70.125", class = "iot" }
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

  address = each.value.subnet
  gateway = each.value.gateway
  # The router's address *in that class* is the resolver, so resolution never leaves the VLAN and the
  # dependency on the router is explicit. `iot` keeps public DNS deliberately: that class must not be able
  # to resolve an internal name, which makes resolution itself a class boundary. See docs/dns.md.
  dns_server = each.key == "iot" ? ["8.8.8.8"] : [each.value.gateway]
  comment    = "${local.managed_by} (${var.router_name}) — ${each.key}"
}

# Static leases: the addresses the agent's inference path is written against. Declared here so
# they exist before anything moves, rather than being discovered as a broken endpoint later.
resource "routeros_ip_dhcp_server_lease" "reserved" {
  for_each = local.dhcp_reservations

  address     = each.value.address
  mac_address = each.value.mac
  server      = routeros_ip_dhcp_server.class[each.value.class].name
  comment     = "${local.managed_by} — fixed identity: the address its name resolves to"
}
