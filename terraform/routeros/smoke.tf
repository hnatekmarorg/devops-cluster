# Read-only smoke test: proves API connectivity, credentials and provider/IPv6
# schema compatibility on every `plan`, creates and changes NOTHING. Its outputs
# are printed by `tofu plan` and end up in the PR comment, so each plan carries
# a live fingerprint of the device it was computed against.
#
# Reads need the `read` policy only — the read credential (`agent-ro`) is
# enough, which is what plan-on-PR and the nightly drift run use.

data "routeros_system_resource" "this" {}

data "routeros_interfaces" "all" {}

data "routeros_ip_addresses" "all" {}

data "routeros_ip_arp" "all" {}
