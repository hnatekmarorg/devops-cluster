output "board_name" {
  description = "Device the plan was computed against (must be the RB5009)."
  value       = data.routeros_system_resource.this.board_name
}

output "routeros_version" {
  description = "RouterOS version — the upgrade pending in Phase 0 shows up here."
  value       = data.routeros_system_resource.this.version
}

output "architecture" {
  value = data.routeros_system_resource.this.architecture_name
}

output "vlans_created" {
  description = "VLAN interfaces this module owns, with their gateway addresses."
  value = {
    for k, v in routeros_interface_vlan.vlan :
    k => "${v.name} (gateway ${routeros_ip_address.vlan_gateway[k].address})"
  }
}

output "address_list_names" {
  description = "Firewall address lists this module owns (rules come in a later stage)."
  value       = sort(distinct([for entry in local.address_list_entries : entry.list]))
}

output "existing_addresses" {
  description = "Addresses currently on the router — the baseline the VLAN carve will be measured against."
  value       = [for a in data.routeros_ip_addresses.all.addresses : "${a.interface} -> ${a.address}"]
}

output "interface_count" {
  value = length(data.routeros_interfaces.all.interfaces)
}
