terraform {
  required_version = ">= 1.10"

  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
      # Pinned exactly, like the router module: this provider manages switches carrying every VLAN
      # in the estate, and its resource schemas shift between minor versions.
      version = "1.99.1"
    }
  }
}
