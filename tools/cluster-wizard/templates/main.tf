# The {{.ClusterName}} cluster.
#
# This is the whole root. Everything that used to be a sequence of hand-run commands and a set of
# trap-avoiding patches lives in the module — the disk install, the declared network interface, the time
# servers, the by-kind kubelet patch, the VLAN tag, the CPU type. What remains here is only what is
# genuinely specific to *this* cluster.
#
#   tofu init -backend-config="key=cluster-{{.ClusterName}}/terraform.tfstate"   # one state per cluster
#   tofu plan
#   tofu apply

module "cluster" {
  source = "../../modules/talos-cluster"

  cluster_name     = "{{.ClusterName}}"
  cluster_endpoint = "{{.Endpoint}}"
{{- if .MultiControlPlane }}
  # NOTE for review: this endpoint currently resolves to {{(index .Nodes 0).Name}}, so the API is a single
  # point of failure even though etcd is HA. A VIP out of the reserved 172.16.48.0/20 is the fix and is
  # not implemented yet.
{{- end }}

  talos_version = "{{.TalosVersion}}"

  proxmox_node   = "{{.ProxmoxNode}}"
  template_vm_id = {{.TemplateVmId}}
  # The TEMPLATE lives on {{.TemplateStorage}}; each node's own disk chooses its datastore below.
  template_storage = "{{.TemplateStorage}}"
  vlan_id          = {{.VlanId}}

  storage_bridge = "{{.StorageBridge}}"

  # Addresses and MACs come from the router's reservations (terraform/routeros/dhcp.tf), so a rebuild
  # lands on the same addresses and nothing that refers to them by name has to change.
  nodes = [
{{- range .Nodes }}
    {
      name      = "{{.Name}}"
      role      = "{{.Role}}"
      mac       = "{{.MAC}}"
      address   = "{{.Address}}"
      cores     = {{.Cores}}
      memory_mb = {{.MemoryMb}}
      disk_gb   = {{.DiskGb}}
{{- if eq .Role "controlplane" }}
      # etcd is fsync-bound. On iSCSI this shows up as `etcdserver: request timed out`, and every
      # lease holder exits together — controller-manager, scheduler, CCM, Karpenter. Local storage here.
{{- else }}
      # A worker wants the room for images, and losing it does not take the cluster with it.
{{- end }}
      storage = "{{.Storage}}"
    },
{{- end }}
  ]

  # The module's health gate cannot pass on a cluster that sets a hostname override — see the note in
  # terraform/modules/talos-cluster/main.tf. With it off, the bootstrap's own waits catch a cluster that
  # did not come up.
  check_health = {{.CheckHealth}}

  # OIDC via a structured AuthenticationConfiguration (the API server runs with
  # --authentication-config; the legacy --oidc-* flags are gone in 1.14). Roles arrive in the
  # top-level `groups` claim, the estate's convention.
  oidc_enabled = {{.OidcEnabled}}

  # Talos already adds the cluster endpoint's hostname to the API server certificate automatically, so
  # these are for the OTHER ways in — connecting by node name, and localhost.
  cert_sans = [
{{- range .Nodes }}
    "{{.Address}}",
{{- end }}
    "127.0.0.1",
{{- range .Nodes }}
    "{{.Name}}.srv.hnatekmar.dev",
{{- end }}
    "{{.ClusterName}}-k8s.srv.hnatekmar.dev",
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
# two are the seam for the image story: the PVE template Karpenter clones boot.
output "schematic_id" {
  description = "The node image's schematic, as the provider registered it."
  value       = module.cluster.schematic_id
}

output "template_image_url" {
  description = "The image a PVE template is built from — see terraform/docs/cluster-autoscaling.md."
  value       = module.cluster.template_image_url
}

# The credential-free kubeconfig belongs in git next to the cluster definition: it carries no secret
# (endpoint, public CA, a kubelogin exec block), so committing it is safe. Regenerate it after every
# rebuild — the CA changes then.
output "oidc_kubeconfig" {
  description = "OIDC kubeconfig: no credential in it, safe to commit. Requires the kubelogin plugin."
  value       = nonsensitive(module.cluster.oidc_kubeconfig)
}
