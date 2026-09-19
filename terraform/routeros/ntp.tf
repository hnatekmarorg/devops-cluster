# The estate's own time source.
#
# Why this file exists: the router has always run the NTP *client* (europe pool) and has never served
# time. Measured 2026-09-18: `/system ntp server` reads `enabled=false`, udp/123 is unanswered on all
# five of its addresses, and that is why `ntp-none` had to be set on the DHCP network objects — the
# device's own silence is not "off", and a client honouring option 42 was being handed a source that
# never answers. Talos on `dev-w1` retried `172.16.40.1:123` indefinitely instead of falling back to
# its `time.cloudflare.com` default.
#
# That cost nothing while every device had egress of its own. It stopped being true on 2026-09-19, when
# the storage island's switch (CRS317) gained a management link: that device is deliberately denied a
# default route, so it cannot reach the public pool, and it is the first device on the estate whose
# clock has no other way to be right. A switch whose clock drifts makes every log, backup filename and
# certificate check lie (docs/network-wiring.md).
#
# So the router becomes the estate's time source. It is already synchronized to the pool, which is what
# makes this a one-line change; `use_local_clock = false` keeps it honest — it serves the clock it has
# *synchronized*, and stops answering if it loses the pool, rather than handing out free-running time.

import {
  to = routeros_system_ntp_client.this
  id = "."
}

# Adoption only, no behaviour change. Declared rather than left implicit for the usual reason: the
# provider plans `-> null` for an attribute the file omits, i.e. silence would *clear* a setting the
# device wants set (the same lesson as `vrf` and `dynamic_lease_identifiers`).
resource "routeros_system_ntp_client" "this" {
  enabled = true
  mode    = "unicast"
  servers = ["0.europe.pool.ntp.org", "1.europe.pool.ntp.org", "2.europe.pool.ntp.org", "3.europe.pool.ntp.org"]
  vrf     = "main"
}

import {
  to = routeros_system_ntp_server.this
  id = "."
}

# The change. Every other attribute is stated because it is what the device already holds — this object
# has no `comment`, so the reasoning lives here.
#
# `broadcast_addresses` is the case that proves the rule: the device reports `0.0.0.0` there, so declaring
# `""` (the obvious "empty") made the plan want to *clear* the field. The plan caught it; the config now
# states what the device holds instead.
#
# Not done in the same breath: advertising this server through DHCP option 42. The `ntp-none = true` on
# the DHCP network objects stays until that is a decision rather than a side effect, because for `iot`
# and `lab` udp/123 to the router is dropped by the enforced input denies — option 42 would hand those
# segments a source they cannot reach, which is the same failure one layer down.
resource "routeros_system_ntp_server" "this" {
  auth_key            = "none"
  broadcast           = false
  broadcast_addresses = "0.0.0.0"
  enabled             = true
  local_clock_stratum = 5
  manycast            = false
  multicast           = false
  use_local_clock     = false
  vrf                 = "main"
}
