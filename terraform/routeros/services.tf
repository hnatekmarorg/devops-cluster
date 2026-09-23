# The router's own management services — declared here because the estate's *control* path runs over one
# of them.
#
# Measured 2026-09-16, and it cost most of a day: `api` carried
# `available-from=172.16.100.0/24,172.16.101.0/24` — the compat subnet, plus the vestigial work subnet
# that has carried no link since the work experiment (`docs/agent/network-wiring.md`). A source outside that
# list has its connection closed **during the login**, and the router writes nothing to the log for it,
# so the symptom was `could not login: EOF` from a runner whose reachability, credential and health were
# all fine — while the *same* runner logged in to the CRS326 without complaint, which is what made it
# read as a device-specific mystery instead of a filter.
#
# The defect was not the address. It was that a setting the control path depends on existed only in the
# device's memory: nothing in this repository knew it was there, so nothing could review it, and it
# failed silently the moment the runner left the subnets it named. The allow-list now lives where the
# rest of the estate's intent lives, and a plan shows it.
#
# Policy: the **mgmt class** — where privilege lives (Q27), and where both the runner and the operator
# box sit — plus compat while that segment drains. A class network rather than the runner's address, on
# purpose: the runner has already moved twice (`.100.126` → `172.16.10.202` → `172.16.10.140`), and a
# per-host filter is precisely what failed quietly the first time.
#
# The vestigial `172.16.101.0/24` is dropped rather than carried forward: no link carries it, so nothing
# can arrive from it.
#
# `ssh`, `winbox`, `www` and `api-ssl` are deliberately **not** declared yet — they carry no filter
# today, and adopting an object means restating what the device has. They come in when someone reads
# them off the device; until then, silence here is honest rather than an oversight.

locals {
  # Who may reach the device's control plane. Kept beside the resource that uses it rather than in
  # `main.tf`'s address lists: those are the *traffic* classes the firewall matches, while this is an
  # access list for the device's own daemon — the firewall never sees it. It is a string because that is
  # what the device and the provider both speak (`available-from`: a comma-separated prefix list).
  service_admin_sources = "172.16.0.0/20,172.16.100.0/24"
}

resource "routeros_ip_service" "api" {
  numbers = "api"
  port    = 8728
  address = local.service_admin_sources

  # Declared, not omitted: the provider reads the device's value back and plans `-> null` where this file
  # is silent, i.e. silence would *clear* a setting the device wants set — the same lesson as `disabled`
  # in `dhcp.tf`. `vrf` is absent for the opposite reason: the schema offers it and the device rejects
  # it ("unknown parameter vrf", see `stage2-filtering.tf`).
  disabled = false
}
