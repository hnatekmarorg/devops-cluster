# Stage 3, phase 1 — the matrix as counters, not verdicts.
#
# terraform/docs/firewall-matrix.md is the argument; this file is the first slice of it. RouterOS's
# `action=log` records the packet and **keeps processing**, so every rule here observes without
# blocking — the estate behaves exactly as it did before this file existed. Phase 2 flips `action` to
# `drop`, one attribute per rule, once the logs have said who actually talks to what.
#
# Scope of this phase: the class the matrix calls untrusted — **iot** (`172.16.64.0/20`), the whole
# WiFi segment, the TV, the gaming PC, phones, and the TV-isolation gateway. Its row in the matrix
# reads "internet ✓ only"; everything internal is the VPN's job, later.
#
# The destination lists are not declared here: `main.tf` already carries the class networks as
# address-list entries (`mgmt-nets`, `srv-nets`, `lab-nets`, `vpn-nets`, `svc-vips`, `lan-nets`), so
# these rules are references to that same data rather than a second copy of it.

locals {
  # iot may not *initiate* to any of these. Each pair gets its own rule and its own log prefix so the
  # report can count them separately instead of aggregating one indistinguishable stream of denies.
  iot_deny_targets = {
    MGMT   = "mgmt-nets" # the admin plane, including switch and IPMI management
    SRV    = "srv-nets"  # the keepers: NAS, git, identity, registry
    VIP    = "svc-vips"  # service VIPs (ingress), which are internal by definition
    LAB    = "lab-nets"  # compute and sandboxes
    VPN    = "vpn-nets"  # tunnel clients
    COMPAT = "lan-nets"  # the legacy flat segment — still inhabited, therefore still internal
  }
}

resource "routeros_ip_firewall_filter" "iot_deny_log" {
  for_each = local.iot_deny_targets

  chain            = "forward"
  action           = "log"
  src_address_list = "iot-nets"
  dst_address_list = each.value
  log_prefix       = "MTX-IOT>${each.key} "
  comment          = "matrix phase 1 (log-only): iot does not initiate to ${each.key} — firewall-matrix.md"
}

# The router is part of the admin plane, and today every class can reach it: the `LAN` interface list
# holds all six class VLANs and the input chain's rule is `drop all not coming from LAN`, so an iot
# device can open winbox/api/ssh on the router right now. Logged before it is denied, like the rest.
resource "routeros_ip_firewall_filter" "iot_router_admin_log" {
  chain            = "input"
  action           = "log"
  protocol         = "tcp"
  src_address_list = "iot-nets"
  dst_port         = "22,80,443,8291,8728,8729"
  log_prefix       = "MTX-IOT>ROUTER "
  comment          = "matrix phase 1 (log-only): iot does not administer the router (ssh, www, winbox, api)"
}

# Not in this phase, deliberately: `lab → mgmt` (the matrix's other confident row), the service-boundary
# rows port by port (`lab → srv`), and the compat row's deletion. Each is its own reviewable step —
# the order is the matrix's own: iot, then lab, then srv, then mgmt, compat last.
