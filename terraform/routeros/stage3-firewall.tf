# Stage 3, phase 2 — the matrix enforced for iot, and still counted.
#
# terraform/docs/firewall-matrix.md is the argument; this file is its first enforced slice. Phase 1
# (PR #60) measured with `action=log`: a six-hour-and-one-read sample showed iot's only spontaneous
# internal traffic was a phone reaching a *published* service through the WAN address, plus whatever the
# probe was told to try. Martin's call, 2026-09-15: **iot gets WAN and nothing else, no exceptions** —
# so the hairpin path that a `connection-nat-state=dstnat` carve-out would have preserved is denied
# with the rest of it. An iot device that wants one of the estate's public services reaches it over the
# internet, not through our own NAT. (If that ever needs revisiting, the honest fix is not an exception
# in this chain but `in-interface-list=WAN` on the published `dstnat` rules, so hairpin stops existing
# for every class at once instead of being special-cased for one.)
#
# `action=drop` **with `log=true`**: the drop is enforced and the attempt is still written to the log
# under the same `log-prefix`, so `scripts/matrix-deny-report.py` keeps reading the same stream — now
# reporting what the estate *did* lose rather than what it would have lost.
#
# Scope: **iot** (`172.16.64.0/20`) — the whole WiFi segment, the TV, the gaming PC, phones, and the
# TV-isolation gateway. Its row in the matrix is "internet ✓ only"; internal reach is the VPN's job,
# later. Destination lists are references, not copies: `main.tf` carries the class networks as
# address-list entries.
#
# Placement. RouterOS has no numeric priority — rule *order* is the priority, first match wins — and the
# provider's lever, `place_before`, is write-time intent only: no attribute models where a rule sits, so
# `plan` cannot see placement. The forward rules below therefore set **none**: leaving it unset appends
# them to the end of the chain, which is the anchor they want —
#
#   * BELOW `accept established,related,untracked`. A *reply* packet from iot to an internal peer
#     matches the same tuple as the deny (src `iot-nets`, dst `<class>-nets`), so a rule above
#     connection tracking would break every flow an internal host initiates *into* iot — the weekly
#     digest's ssh to the TV gateway is precisely such a flow, and it is verified working after every
#     change here.
#   * BELOW the chain's existing accepts, which is safe because they are scoped: the published-service
#     accepts match `connection-nat-state=dstnat` AND `dst-address-list=wan`, so east-west iot traffic
#     cannot reach them, and the other drops are MAC- or address-specific. (Measured, not assumed.)
#
# The one exception is the input pair further down (`iot_router_deny` + `iot_router_dhcp`): a catch-all
# drop and the DHCP accept it must not swallow are created in the same apply, and two rules created in
# one apply have no order between them unless it is stated. There the anchor is explicit.
#
# The invariant to protect in review: these rules are the last judgement on traffic no accept claimed,
# so a *new* accept placed above them must be narrow — a named address or port with a class reason — or
# it silently shadows the class policy. `scripts/matrix-order-check.py` asserts exactly that against the
# live router. Order *among* the matrix rules does not matter: the pairs are disjoint and every rule for
# one class carries the same action.

# Renamed in phase 2: they are no longer "log-only", so the resource names say what the policies do.
# `moved` keeps the change in place — a rename without it would destroy and re-create live firewall
# rules, briefly leaving the class unpoliced and hiding the real change in a noisy plan.
moved {
  from = routeros_ip_firewall_filter.iot_deny_log
  to   = routeros_ip_firewall_filter.iot_deny
}

moved {
  from = routeros_ip_firewall_filter.iot_router_admin_log
  to   = routeros_ip_firewall_filter.iot_router_admin
}

locals {
  # iot may not reach these at all. Each pair gets its own rule and its own log prefix so the report can
  # count them separately instead of aggregating one indistinguishable stream of denies.
  iot_deny_targets = {
    MGMT   = "mgmt-nets" # the admin plane, including switch and IPMI management
    SRV    = "srv-nets"  # the keepers: NAS, git, identity, registry
    VIP    = "svc-vips"  # service VIPs (ingress), which are internal by definition
    LAB    = "lab-nets"  # compute and sandboxes
    VPN    = "vpn-nets"  # tunnel clients
    COMPAT = "lan-nets"  # the legacy flat segment — still inhabited, therefore still internal
  }
}

resource "routeros_ip_firewall_filter" "iot_deny" {
  for_each = local.iot_deny_targets

  chain            = "forward"
  action           = "drop"
  log              = true
  src_address_list = "iot-nets"
  dst_address_list = each.value
  log_prefix       = "MTX-IOT>${each.key} "
  comment          = "matrix phase 2 (enforced, logged): iot does not reach ${each.key} — firewall-matrix.md"
}

# The router itself. Every class can reach it by default — the `LAN` interface list holds all six class
# VLANs and the input chain's rule is `drop all not coming from LAN` — so phase 1 demonstrated an iot
# device opening winbox (`172.16.70.1:8291`) while the log recorded it.
#
# **This is a default-deny, and the first version was not: it enumerated ports.** An `nmap` from the probe
# then showed why that shape is wrong — it cannot be complete. `22/80/443/8291` were filtered, but
# `2000/tcp` and `8080/tcp` answered, because the router's `www` service lives on **8080** here (not the
# 80 the list assumed) and `btest` listens on 2000. An enumerated list of *admin* ports ages badly and
# knows nothing about services nobody has added yet; a default-deny does.
#
# Only the segment's own plumbing is allowed, and each line is a reason:
#   * DHCP (udp 67/68) — without it the segment has no addresses at all. Explicit, because a catch-all
#     drop makes the input chain's *fall-through* accept stop applying.
#   * ICMP — not listed here: defconf's `accept ICMP` sits above this rule, so ping and PMTUD keep working.
#
# NTP (udp 123) is deliberately **not** allowed even though the router serves it: the probe uses public
# pool servers, and if any iot device does want the router's clock the drop is logged under this same
# prefix — measured rather than guessed, and one accept rule away.
resource "routeros_ip_firewall_filter" "iot_router_deny" {
  chain            = "input"
  place_before     = routeros_ip_firewall_filter.iot_router_dhcp.id
  action           = "drop"
  log              = true
  src_address_list = "iot-nets"
  log_prefix       = "MTX-IOT>ROUTER "
  comment          = "matrix phase 2 (enforced, logged): iot reaches the router only for DHCP and ICMP"
}

# Ordered *before* the drop above: without this, DHCP from the whole segment would be the first casualty
# of the catch-all, and the ordering of two rules created in the same apply is not something to leave to
# chance. `place_before` anchored to a Terraform-managed rule is the provider's supported way to say it.
resource "routeros_ip_firewall_filter" "iot_router_dhcp" {
  chain            = "input"
  action           = "accept"
  protocol         = "udp"
  src_address_list = "iot-nets"
  dst_port         = "67,68"
  comment          = "iot keeps the one router service a segment cannot live without (DHCP)"
}

moved {
  from = routeros_ip_firewall_filter.iot_router_admin
  to   = routeros_ip_firewall_filter.iot_router_deny
}

# Not in this phase, deliberately: `lab → mgmt` (the matrix's other confident row), the service-boundary
# rows port by port (`lab → srv`), and the compat row's deletion. Each is its own reviewable step — the
# order is the matrix's own: iot, then lab, then srv, then mgmt, compat last.
