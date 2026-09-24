# Credentials and endpoint come from the environment, like every other root here: the bpg/proxmox provider
# reads PROXMOX_VE_ENDPOINT plus either PROXMOX_VE_API_TOKEN or PROXMOX_VE_USERNAME/PROXMOX_VE_PASSWORD,
# and honours PROXMOX_VE_INSECURE for a self-signed PVE certificate (which balteus has). Nothing sensitive
# belongs in this file.
#
# The Talos provider needs no configuration: every resource takes an explicit client_configuration, which
# is what lets a cluster be created without any pre-existing trust.
provider "proxmox" {}
