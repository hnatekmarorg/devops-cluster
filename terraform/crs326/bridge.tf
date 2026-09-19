# The CRS326's bridge domain, adopted as-is — the baseline its filtering step is applied against.
#
# Same shape as the RB5009's: the plan for this file is imports only, zero changes, which is the
# proof that the baseline is faithful. Ports are annotated with what they belong to, because a
# list of twenty-four identical bridge-port blocks is otherwise unreadable.
#
# Addresses (172.16.100.2 here, plus the dormant 192.168.88.1) are deliberately NOT adopted in this
# wave: the management move is its own reviewed step, and the router taught us that an address
# carries a writability trap (`vrf`) worth meeting deliberately.
#
# The import ids are RouterOS' internal ids at the time of writing, used only for the adoption;
# after the first apply they can be deleted. Re-read with /interface/bridge print and
# /interface/bridge/port print.

import {
  to = routeros_interface_bridge.bridge
  id = "*1B"
}
import {
  to = routeros_interface_bonding.bukefalos
  id = "*1E"
}
import {
  to = routeros_interface_bridge_port.ether3
  id = "*2"
}
import {
  to = routeros_interface_bridge_port.ether4
  id = "*3"
}
import {
  to = routeros_interface_bridge_port.ether5
  id = "*4"
}
import {
  to = routeros_interface_bridge_port.ether6
  id = "*5"
}
import {
  to = routeros_interface_bridge_port.ether7
  id = "*6"
}
import {
  to = routeros_interface_bridge_port.ether8
  id = "*7"
}
import {
  to = routeros_interface_bridge_port.ether9
  id = "*8"
}
import {
  to = routeros_interface_bridge_port.ether10
  id = "*9"
}
import {
  to = routeros_interface_bridge_port.ether11
  id = "*A"
}
import {
  to = routeros_interface_bridge_port.ether12
  id = "*B"
}
import {
  to = routeros_interface_bridge_port.ether13
  id = "*C"
}
import {
  to = routeros_interface_bridge_port.ether14
  id = "*D"
}
import {
  to = routeros_interface_bridge_port.ether15
  id = "*E"
}
import {
  to = routeros_interface_bridge_port.ether16
  id = "*F"
}
import {
  to = routeros_interface_bridge_port.ether17
  id = "*10"
}
import {
  to = routeros_interface_bridge_port.ether18
  id = "*11"
}
import {
  to = routeros_interface_bridge_port.ether19
  id = "*12"
}
import {
  to = routeros_interface_bridge_port.ether20
  id = "*13"
}
import {
  to = routeros_interface_bridge_port.ether21
  id = "*14"
}
import {
  to = routeros_interface_bridge_port.ether22
  id = "*15"
}
import {
  to = routeros_interface_bridge_port.sfp_sfpplus1
  id = "*18"
}
import {
  to = routeros_interface_bridge_port.sfp_sfpplus2
  id = "*19"
}
import {
  # the host's LAN port on `ether2`, adopted at the id the device actually holds: dissolving the bond
  # took the old entry (`*1A`) with it, so the live entry is `*1C`.
  #
  # The address is deliberately one the state has never held. An import block whose target is already in
  # the state is *skipped* ("already managed"), and the refresh then drops the stale entry as vanished --
  # leaving a `create` planned for a port that exists, which RouterOS refuses, so the plan would never
  # come back empty. Both halves of that are measured, not guessed.
  to = routeros_interface_bridge_port.pve_lan
  id = "*1C"
}

# the flat bridge: every port pvid=1, `vlan-filtering` off, no VLAN entries. Adopted as-is so the filtering step is a one-attribute diff.
resource "routeros_interface_bridge" "bridge" {
  admin_mac           = "2C:C8:1B:88:58:3D"
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

# The PVE host's LAN bond is gone: dissolved host-side and deleted on the device, so nothing recreates
# a husk here. Its second member is now `ether2`, carrying the host's LAN directly (see the port below).
#
# CEILING WORTH KNOWING: the CI runner runs on a guest *behind this port*. An apply that interrupts
# `ether2` therefore kills its own runner mid-flight — which is exactly how the first attempt at this
# change died, leaving the device correct and the state stale. Per-guest tags never touch this link.


# The second server's reservation — **now one member**: `ether24` left the bond for the island switch's
# out-of-band link (see the `ether24` port below). A one-port 802.3ad bond aggregates nothing, which is
# the honest representation: bukefalos' hardware takes the freed port back when it arrives, and a
# two-member bond that cannot form would only mislead the next reader.
resource "routeros_interface_bonding" "bukefalos" {
  arp                  = "enabled"
  arp_interval         = "100ms"
  arp_ip_targets       = ""
  arp_timeout          = "auto"
  disabled             = false
  down_delay           = "0ms"
  lacp_mode            = "active"
  lacp_rate            = "30secs"
  link_monitoring      = "mii"
  mii_interval         = "100ms"
  min_links            = 0
  mode                 = "802.3ad"
  mtu                  = 1500
  name                 = "bukefalos"
  primary              = "none"
  slaves               = ["ether23"]
  transmit_hash_policy = "layer-3-and-4"
  up_delay             = "0ms"
}

# **The island switch's out-of-band link** — the far end of the CRS317's 1 G management port.
#
# Measured 2026-09-19: `ether24` has carried zero bytes since boot and its bond is down, so this costs
# nothing today. What it buys is a path to the CRS317 that does not run through the storage island:
# that switch is reachable only in-band, across the same LACP bond that carries every VM disk's iSCSI,
# so a bad bridge, VLAN or MTU change there is a lockout whose only way back is a console cable. It is
# also the next device to come under this module's IaC, and a plan needs a reachable endpoint.
#
# Untagged access in mgmt, exactly like the escape hatch (`ether3`) and the IPMI port (`ether7`): the
# CRS317's management port cannot tag, so it lands in VLAN 10 and nowhere else. Its own side keeps no
# default route, so the island stays unrouted from mgmt while the device stays manageable.
#
# CEILING, and the reason the CRS317 side is a coordinated change: **this switch is not jumbo-capable**
# (every port `l2mtu 1592`), while the CRS317's ports are 9000/9000. The CRS317 must set `mtu = 1500`
# on its management port before this cable is plugged — otherwise it emits frames this switch cannot
# forward, and only for large packets, so small management traffic keeps working and the fault reads as
# intermittent.
resource "routeros_interface_bridge_port" "ether24" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "CRS317 management — untagged VLAN 10 only"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-only-untagged-and-priority-tagged"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether24"
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

  # Ordering is load-bearing: the bridge port cannot be created while `ether24` is still a bond slave,
  # and the provider cannot infer that from the two resources' shapes — there is no attribute linking
  # them. Nothing else depends on the bond, so this is the whole ordering requirement.
  depends_on = [routeros_interface_bonding.bukefalos]
}

# The PVE host's LAN port — a bare `ether2` since the LACP bond was dissolved. Untagged in compat
# (pvid 1, unchanged) and tagged for every class, which is what lets guests move one at a time.
resource "routeros_interface_bridge_port" "pve_lan" {
  auto_isolate      = false
  bpdu_guard        = false
  bridge            = "bridge"
  broadcast_flood   = true
  disabled          = false
  edge              = "auto"
  fast_leave        = false
  frame_types       = "admit-all"
  horizon           = "none"
  hw                = true
  ingress_filtering = true
  interface         = "ether2"
  # The one write this change makes. The entry was created by hand during the repair, so RouterOS reports
  # this as `auto` (the provider reads that as unset) while every sibling carries 10. Expressing `auto`
  # is not possible -- the attribute takes a number -- so the config asserts 10, making the port uniform
  # with its 22 siblings. Inert with STP off, which is how this bridge runs.
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

# The idle bond has no bridge port on the device — it was removed with the other dead ports, and this
# resource went with it. The bond itself stays: it is the second server's reservation.

resource "routeros_interface_bridge_port" "ether10" {
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
  interface               = "ether10"
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

resource "routeros_interface_bridge_port" "ether11" {
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
  interface               = "ether11"
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

resource "routeros_interface_bridge_port" "ether12" {
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
  interface               = "ether12"
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

resource "routeros_interface_bridge_port" "ether13" {
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
  interface               = "ether13"
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

resource "routeros_interface_bridge_port" "ether14" {
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
  interface               = "ether14"
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

resource "routeros_interface_bridge_port" "ether15" {
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
  interface               = "ether15"
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

# → dumb switch → AP + TV + gaming PC: one cable, one segment, therefore one class (iot).
#
# **This is the iot segment's access port** (flipped 2026-09-15, tested with the TV-isolation gateway
# before the rest of the segment was trusted to it). The dumb switch was measured first: it cannot tag,
# and neither can the Deco, the TV or the gaming PC — so this is an untagged access port on VLAN 70 and
# nothing else. `admit-only-untagged-and-priority-tagged` also drops whatever a device emits tagged.
resource "routeros_interface_bridge_port" "ether16" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "iot access port — dumb switch: Deco, TV, gaming PC, probe"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-only-untagged-and-priority-tagged"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "ether16"
  internal_path_cost      = 10
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  path_cost               = "10"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 70
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

resource "routeros_interface_bridge_port" "ether17" {
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
  interface               = "ether17"
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

# → RB5009 `ether4` — the estate's single router link, 1 Gb
resource "routeros_interface_bridge_port" "ether18" {
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
  interface               = "ether18"
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

resource "routeros_interface_bridge_port" "ether19" {
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
  interface               = "ether19"
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

resource "routeros_interface_bridge_port" "ether20" {
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
  interface               = "ether20"
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

resource "routeros_interface_bridge_port" "ether21" {
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
  interface               = "ether21"
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

resource "routeros_interface_bridge_port" "ether22" {
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
  interface               = "ether22"
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

# **the escape port** — no cable today; becomes an access port in the mgmt VLAN before anything else changes
resource "routeros_interface_bridge_port" "ether3" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  comment                 = "defconf"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-only-untagged-and-priority-tagged"
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
  pvid                    = 10
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

# → CSS610 Port7: the middle hop for charon, the four Sparks' management and the spine's management
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

resource "routeros_interface_bridge_port" "ether5" {
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
  interface               = "ether5"
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

# balteus' IPMI (`.46`, `3c:ec:ef:73:09:9d`) — out-of-band plane
resource "routeros_interface_bridge_port" "ether7" {
  auto_isolate    = false
  bpdu_guard      = false
  bridge          = "bridge"
  broadcast_flood = true
  # The out-of-band plane's access port: balteus' IPMI/BMC (`3C:EC:EF:73:09:9D`, address `.46` in
  # whichever segment it lives in). Untagged VLAN 10 and nothing else, exactly like the escape port
  # `ether3` — the BMC cannot tag, so it must not be reachable in compat and must not inject another
  # segment's traffic. Until 2026-09-15 it was an ordinary compat port (`pvid = 1`, `admit-all`).
  comment                 = "IPMI access port — untagged VLAN 10 only"
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-only-untagged-and-priority-tagged"
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
  pvid                    = 10
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

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

resource "routeros_interface_bridge_port" "ether9" {
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
  interface               = "ether9"
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

resource "routeros_interface_bridge_port" "sfp_sfpplus1" {
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

resource "routeros_interface_bridge_port" "sfp_sfpplus2" {
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
  interface               = "sfp-sfpplus2"
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
