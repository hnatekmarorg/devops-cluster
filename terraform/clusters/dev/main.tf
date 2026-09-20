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

  # The node image is NOT an input any more: the module registers it (talos_image_factory_schematic) from
  # `talos_schematic_extensions`, whose defaults carry qemu-guest-agent, iscsi-tools and util-linux-tools.
  # So there is no hash here to drift out of sync with a schematic file.
  #
  # What the extension list does and does not achieve: a NEW node gets the extensions at install, a
  # Karpenter clone only when the PVE template is rebuilt (it boots the template's installed disk and never
  # reinstalls), and an existing node only when it is rolled. See terraform/docs/cluster-autoscaling.md.
  talos_version = "v1.14.1"

  proxmox_node   = "balteus"
  template_vm_id = 9000
  # The TEMPLATE lives on iscsi; each node's own disk chooses its datastore below.
  template_storage = "iscsi"
  vlan_id          = 40

  # The storage LAN (`192.168.88.0/24`, vmbr2 on balteus, jumbo MTU, DHCP): every node has its own
  # 10 Gbps link to the NAS, which is the rule both storage tiers are built on.
  #
  # ON, and the comment used to describe it as deliberately off — it was enabled when the storage tiers
  # went in, and the one-off cost was a roll: applying this reconfigures the running VMs and Talos
  # enumerates a NIC only at boot, so the reboot is what binds the interface. A NEW cluster pays that
  # cost at build time instead, which is why prod sets it from the start.
  storage_bridge = "vmbr2"

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
      # etcd is fsync-bound. On iSCSI this shows up as `etcdserver: request timed out`, and every
      # lease holder exits together — controller-manager, scheduler, CCM, Karpenter. Local storage here.
      storage = "local-lvm"
    },
    {
      name      = "dev-w1"
      role      = "worker"
      mac       = "BC:24:11:0D:00:11"
      address   = "172.16.40.101"
      cores     = 4
      memory_mb = 8192
      disk_gb   = 40
      # A worker wants the room for images, and losing it does not take the cluster with it.
      storage = "iscsi"
    },
  ]

  # The module's health gate cannot pass on a cluster that sets a hostname override — see the note in
  # terraform/modules/talos-cluster/main.tf. With it off, the bootstrap's own waits catch a cluster that
  # did not come up, and the apply stops reporting a red job for a cluster that is fine.
  check_health = false

  # OIDC via a structured AuthenticationConfiguration (the API server runs with
  # --authentication-config; the legacy --oidc-* flags are gone in 1.14). Roles arrive in the
  # top-level `groups` claim, the estate's convention.
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

# Re-exported because a module's outputs are invisible from the root until it re-declares them — and these
# two are the seam for the OTHER half of the image story: the PVE template Karpenter clones boot.
output "schematic_id" {
  description = "The node image's schematic, as the provider registered it."
  value       = module.cluster.schematic_id
}

output "template_image_url" {
  description = "The image a PVE template is built from — see terraform/docs/cluster-autoscaling.md."
  value       = module.cluster.template_image_url
}

# The credential-free kubeconfig belongs in git next to the cluster definition: it carries no secret
# (endpoint, public CA, a kubelogin exec block), so committing it is safe and means nobody has to be
# handed a file. Regenerate it after every rebuild — the CA changes then.
output "oidc_kubeconfig" {
  description = "OIDC kubeconfig: no credential in it, safe to commit. Requires the kubelogin plugin."

  # nonsensitive() is deliberate, not an oversight. This output derives from the kubeconfig resource,
  # which holds the cluster's client certificate — but what this OUTPUT contains is only the endpoint,
  # the PUBLIC CA and a kubelogin exec block. Marking it sensitive is what would defeat the purpose:
  # the whole point is that it can be committed and shared. Terraform warns because it cannot tell.
  value = nonsensitive(module.cluster.oidc_kubeconfig)
}
