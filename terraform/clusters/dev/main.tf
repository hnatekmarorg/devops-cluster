# The dev cluster.
#
# This is the whole root. Everything that used to be a sequence of hand-run commands and a set of
# trap-avoiding patches lives in the module — the disk install, the declared network interface, the time
# servers, the by-kind kubelet patch, the VLAN tag, the CPU type. What remains here is only what is
# genuinely specific to *this* cluster.
#
#   tofu init -backend-config="key=cluster-dev/terraform.tfstate"   # one state per cluster
#   tofu plan
#   tofu apply

module "cluster" {
  source = "../../modules/talos-cluster"

  cluster_name     = "dev"
  cluster_endpoint = "https://dev-k8s.srv.hnatekmar.dev:6443"

  # Schematic includes siderolabs/qemu-guest-agent — without it Proxmox cannot report guest addresses,
  # and the CCM has nothing to correlate a node with.
  talos_schematic_id = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
  talos_version      = "v1.14.1"

  proxmox_node     = "balteus"
  template_vm_id   = 9000
  template_storage = "iscsi"
  vlan_id          = 40

  # Addresses and MACs come from the router's reservations (terraform/routeros/dhcp.tf), so a rebuild
  # lands on the same addresses and nothing that refers to them by name has to change.
  #
  # 40 GB disks: the previous 30 GB ones filled with images and the nodes went disk-pressure, after which
  # nothing scheduled at all. The install (see the module) is what actually makes that space usable.
  nodes = [
    {
      name      = "dev-cp1"
      role      = "controlplane"
      mac       = "BC:24:11:0D:00:10"
      address   = "172.16.40.100"
      cores     = 4
      memory_mb = 8192
      disk_gb   = 40
    },
    {
      name      = "dev-w1"
      role      = "worker"
      mac       = "BC:24:11:0D:00:11"
      address   = "172.16.40.101"
      cores     = 4
      memory_mb = 8192
      disk_gb   = 40
    },
  ]

  # Legacy --oidc-* flags: roles arrive in the top-level `groups` claim, the estate's convention.
  oidc_enabled = true

  # Talos already adds the cluster endpoint's hostname to the API server certificate automatically
  # (verified: the served cert carries DNS:dev-k8s.srv.hnatekmar.dev), so these are for the OTHER ways
  # in — connecting by node name, and localhost. dev-cp1.srv.hnatekmar.dev resolves to the same address
  # and would otherwise fail TLS verification as a name mismatch.
  cert_sans = [
    "172.16.40.100",
    "127.0.0.1",
    "dev-cp1.srv.hnatekmar.dev",
    "dev-k8s.srv.hnatekmar.dev",
  ]
}

output "kubeconfig" {
  description = "Feed this to ArgoCD as the cluster's registration, and take its certificate-authority-data for the vault's kubernetes auth."
  value       = module.cluster.kubeconfig
  sensitive   = true
}

output "join_config" {
  description = "Become the `user-data` key of the Secret the Karpenter NodeClass references."
  value       = module.cluster.join_config
  sensitive   = true
}

output "nodes" {
  value = module.cluster.nodes
}
