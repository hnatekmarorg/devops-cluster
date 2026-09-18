# The root declares its own providers: a module's required_providers does not satisfy the root's
# `provider` blocks, and without this the proxmox provider resolves to hashicorp/proxmox (which does not
# exist) rather than bpg/proxmox.
terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.70"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.11"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11"
    }
  }
}
