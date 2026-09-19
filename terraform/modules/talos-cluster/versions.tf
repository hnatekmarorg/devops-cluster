terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.70"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "= 0.12.0-rc.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11"
    }
  }
}
