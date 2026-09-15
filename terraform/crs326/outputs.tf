output "board_name" {
  description = "The device this plan actually talked to."
  value       = data.routeros_system_resource.this.board_name
}

output "routeros_version" {
  description = "Live RouterOS version, so a firmware change is visible in the PR that follows it."
  value       = data.routeros_system_resource.this.version
}

output "interface_count" {
  description = "How many interfaces the device reports — a cheap tripwire for a wrong endpoint."
  value       = length(data.routeros_interfaces.all.interfaces)
}

# Deliberately no "bridge_ports" output: the ports are individual resources (one per port, so the
# carve can change one at a time), and HCL cannot enumerate a resource *type* — only a named
# resource. The adoption's port count is visible in the plan itself, which is where it matters.

output "existing_addresses" {
  description = "Addresses on the device, for the same fingerprint reason."
  value       = [for a in data.routeros_ip_addresses.all.addresses : "${a.address} on ${a.interface}"]
}
