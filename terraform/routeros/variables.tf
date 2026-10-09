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

variable "wg_server_private_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = <<-EOT
    The WireGuard server's private key, declared rather than left to the device
    (`routeros_interface_wireguard.private_key` is optional + computed + sensitive,
    and both CI identities carry `!sensitive`, so a device-generated key can never
    be read back — see `wireguard.tf`).

    Supplied by the apply job as TF_VAR_wg_server_private_key from an *environment*
    secret on `routeros-production`, never a repository secret: a repository secret
    is readable by any job a same-repo branch can trigger, which is exactly what the
    write identity's environment scoping exists to prevent (Q14).

    Empty is how a pull request plans this (no secret reaches a plan job) and maps to
    `null` = "not managed here". An apply that runs without the value lets the device
    generate one, which is recoverable only by re-minting every client profile — so
    the secret is a bootstrap step, not an optional nicety.
  EOT
}
