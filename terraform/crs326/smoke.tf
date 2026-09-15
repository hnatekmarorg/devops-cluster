# Read-only data sources: every plan proves connectivity and credentials, and prints a fingerprint
# of the device, so a plan that succeeds against the wrong switch is visible in its own output.
data "routeros_system_resource" "this" {}

data "routeros_interfaces" "all" {}

data "routeros_ip_addresses" "all" {}
