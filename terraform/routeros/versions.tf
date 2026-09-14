# Provider and OpenTofu version pins for the RouterOS module.
#
# The provider pin is exact on purpose: terraform-routeros changes resource
# schemas between minor versions, and this module manages the device that carries
# every VLAN in the estate. Renovate opens PRs for bumps; each one is reviewed
# like any other change.
terraform {
  # 1.10+ for the s3 backend's use_lockfile (state locking without DynamoDB).
  required_version = ">= 1.10.0"

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.1"
    }
  }
}
