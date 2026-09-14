# The bridge domain, adopted as-is — the baseline the VLAN carve is applied against.
#
# Why this file exists
# --------------------
# Stage 1 (`vlan.tf`) *creates* VLAN interfaces and address lists; it touches nothing that
# already exists. Every carve step after that *modifies* existing objects — starting with the
# bridge (`vlan-filtering`) and its nine ports (`pvid`, `frame-types`). OpenTofu can only
# modify what it knows about, so those objects are adopted first, in a change that plans
# **zero changes** to the device. That zero is the proof: once this plans "No changes", the
# baseline is faithful and every later diff is a real one.
#
# Measured plan for this PR (read-only, against the live RB5009):
#     10 to import, 0 to add, 0 to change, 0 to destroy
#
# In scope: the bridge and its ports — the exact set the carve's first steps touch
# (`ether4` → CRS326, `ether1` the escape port). `ether5`, the ISP uplink, was adopted in this
# wave and **removed in wave 2b**: once the WAN is not a bridge member, declaring it here would
# fight the intent. DHCP, firewall, NAT and the addresses follow as their own waves.
#
# Attribute values are exactly what the device reports — generated from it, then trimmed of
# unset/computed noise. They are not preferences, they are the record. `comment = "defconf"`
# and `fast_forward = true` look incidental and are not: a baseline that omits an attribute
# the device actually has plans a change on adoption, which defeats the exercise.
#
# The import ids are RouterOS' internal ids at the time of writing and are used only for the
# adoption; once the first apply has run they can be deleted (they then no-op). To re-read
# them: `/interface/bridge print` and `/interface/bridge/port print`.
#
# Rollback: nothing changes on the device. To undo the adoption itself:
#     tofu state rm routeros_interface_bridge.bridge \
#                  routeros_interface_bridge_port.{ether1,ether2,ether3,ether4,ether5,ether6,ether7,ether8,sfp_sfpplus1}

import {
  to = routeros_interface_bridge.bridge
  id = "*A"
}

import {
  to = routeros_interface_bridge_port.ether1
  id = "*12"
}

import {
  to = routeros_interface_bridge_port.ether2
  id = "*13"
}

import {
  to = routeros_interface_bridge_port.ether3
  id = "*1"
}

import {
  to = routeros_interface_bridge_port.ether4
  id = "*2"
}

import {
  to = routeros_interface_bridge_port.ether6
  id = "*4"
}

import {
  to = routeros_interface_bridge_port.ether7
  id = "*5"
}

import {
  to = routeros_interface_bridge_port.ether8
  id = "*6"
}

import {
  to = routeros_interface_bridge_port.sfp_sfpplus1
  id = "*11"
}

# The defconf bridge: every port pvid=1, `vlan-filtering` off, no VLAN entries — i.e. one flat
# broadcast domain. Adopted as-is so the carve's first step (enabling filtering with everything
# still on compat) is a one-attribute diff against a known baseline.
resource "routeros_interface_bridge" "bridge" {
  admin_mac           = "DC:2C:6E:43:D4:A7"
  ageing_time         = "5m"
  arp                 = "enabled"
  arp_timeout         = "auto"
  auto_mac            = false
  comment             = "defconf"
  dhcp_snooping       = false
  disabled            = false
  fast_forward        = true
  forward_delay       = "15s"
  igmp_snooping       = false
  max_learned_entries = "auto"
  max_message_age     = "20s"
  mtu                 = "auto"
  name                = "bridge"
  port_cost_mode      = "short"
  priority            = "0x8000"
  protocol_mode       = "rstp"
  transmit_hold_count = 6
  vlan_filtering      = true
}

# no link today. **The management escape port**: VLAN 10, untagged-only, so a laptop here lands in
# the mgmt segment and reaches 172.16.10.1 even if the compat segment is misconfigured. It exists
# precisely so a mistake in VLAN 1 cannot take the way back in with it.
resource "routeros_interface_bridge_port" "ether1" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-only-untagged-and-priority-tagged"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether1"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 10
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# carries `172.16.100.1/24` as a bridge slave, and its link is down — the LAN address sits on a dead
# port. Moving it onto the bridge/VLAN interfaces is cut-over risk #1.
resource "routeros_interface_bridge_port" "ether2" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether2"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# no link — spare.
resource "routeros_interface_bridge_port" "ether3" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "defconf"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether3"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# **the LAN uplink to the CRS326** (`ether18`), 1 Gb, measured by counters. The estate's single
# path between router and switches, and the first port that becomes a trunk.
resource "routeros_interface_bridge_port" "ether4" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "defconf"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether4"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# no link — spare.
resource "routeros_interface_bridge_port" "ether6" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "defconf"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether6"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# no link — spare.
resource "routeros_interface_bridge_port" "ether7" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "defconf"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether7"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# no link — spare.
resource "routeros_interface_bridge_port" "ether8" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "defconf"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether8"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# `172.16.101.1/24`, no link — the vestigial work experiment (Martin: unused). Not part of the
# carve; a cleanup candidate.
resource "routeros_interface_bridge_port" "sfp_sfpplus1" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "sfp-sfpplus1"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}
