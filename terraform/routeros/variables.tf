variable "bridge_interface" {
  type        = string
  default     = "bridge"
  description = "Bridge the VLAN interfaces are created on (RB5009: `bridge`)."
}

variable "router_name" {
  type        = string
  default     = "rb5009"
  description = "Short device name, used in object comments and the state key."
}

variable "ai_compute_hosts" {
  type        = string
  default     = "172.16.100.189"
  description = <<-EOT
    Comma-separated addresses of AI compute hosts (the inference box plus the
    DGX Sparks once their addresses are confirmed). Feeds the `ai-compute` and
    `wan-restricted` firewall address lists.
  EOT
}
