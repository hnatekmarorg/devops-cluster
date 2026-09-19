# The prod cluster.
#
# Same module as dev; only what is genuinely specific to *this* cluster lives here. Per the PR body, this
# is a DRAFT: it is the scope of a prod cluster expressed as the diff that would create one, not something
# to apply yet.
#
#   tofu init -reconfigure -backend-config="key=cluster-prod/terraform.tfstate"
#   tofu plan
#   tofu apply
#
# HEALTH GATE OFF, deliberately — and this is about CI, not about this cluster being special. The
# module's gate cannot pass on ANY cluster that sets a hostname override: Talos looks for the control
# plane static pods named after the *machine* hostname (`talos-<auto>`) while the kubelet names them
# after the node (`kube-apiserver-prod-cp1`), so "waiting for all control plane static pods to be
# running" never completes and the apply fails its gate on a perfectly healthy cluster. 7 of its 8
# checks pass; this is the one. Leaving it on would mean every apply of this cluster reports a red job
# for a cluster that came up correctly — which is worse than no gate, because it teaches people to
# ignore red jobs.
#
# Turn it back on when the two names agree (cloud-init meta-data with `local-hostname` — the scope list
# in the PR). Note what replaces it: with the gate off, the BOOTSTRAP's own waits are what catch a
# cluster that did not come up — it waits for the API server, for the CCM to clear the taint, and for
# ArgoCD — so a broken cluster still fails, just later and with a more specific message.

module "cluster" {
  source = "../../modules/talos-cluster"

  cluster_name     = "prod"
  cluster_endpoint = "https://prod-k8s.srv.hnatekmar.dev:6443"

  talos_schematic_id = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
  talos_version      = "v1.14.1"

  proxmox_node     = "balteus"
  template_vm_id   = 9000
  template_storage = "iscsi"
  vlan_id          = 40

  # THE DECISION TO REVIEW: sizing and node count. Three control planes because etcd wants an odd quorum
  # and prod is the cluster that must survive losing one. One worker to start, with Karpenter covering
  # peaks — if prod's steady state needs more than one node, that is an argument for a second worker, not
  # for a bigger autoscaler.
  #
  # Addresses and MACs are the reservations added in the prerequisites PR, so a rebuild lands on the same
  # numbers and nothing that refers to them by name has to change.
  nodes = [
    {
      name      = "prod-cp1"
      role      = "controlplane"
      mac       = "BC:24:11:0D:00:20"
      address   = "172.16.40.120"
      cores     = 4
      memory_mb = 8192
      disk_gb   = 40
      # etcd is fsync-bound: on iSCSI this shows up as `etcdserver: request timed out` and every lease
      # holder exits together. Local storage, same as dev's control plane.
      storage = "local-lvm"
    },
    {
      name      = "prod-cp2"
      role      = "controlplane"
      mac       = "BC:24:11:0D:00:21"
      address   = "172.16.40.121"
      cores     = 4
      memory_mb = 8192
      disk_gb   = 40
      storage   = "local-lvm"
    },
    {
      name      = "prod-cp3"
      role      = "controlplane"
      mac       = "BC:24:11:0D:00:22"
      address   = "172.16.40.122"
      cores     = 4
      memory_mb = 8192
      disk_gb   = 40
      storage   = "local-lvm"
    },
    {
      name    = "prod-w1"
      role    = "worker"
      mac     = "BC:24:11:0D:00:23"
      address = "172.16.40.123"
      # A prod worker carries the workloads, so it is bigger and roomier than dev's: images are what fill
      # a disk here, and iscsi is where the space is.
      cores     = 8
      memory_mb = 16384
      disk_gb   = 80
      storage   = "iscsi"
    },
  ]

  # See the note above the module block. With the gate off, a cluster that did not come up is caught by
  # the bootstrap's waits instead — the API server, the taint, ArgoCD.
  check_health = false

  oidc_enabled = true

  # Talos adds the endpoint hostname to the API server certificate itself; these cover the other ways in.
  # All three control planes are listed so a kubeconfig pointing at any of them verifies — relevant
  # precisely because the endpoint is not a VIP yet.
  cert_sans = [
    "172.16.40.120",
    "172.16.40.121",
    "172.16.40.122",
    "127.0.0.1",
    "prod-cp1.srv.hnatekmar.dev",
    "prod-cp2.srv.hnatekmar.dev",
    "prod-cp3.srv.hnatekmar.dev",
    "prod-k8s.srv.hnatekmar.dev",
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

output "oidc_kubeconfig" {
  description = "OIDC kubeconfig: no credential in it, safe to commit. Requires the kubelogin plugin."
  value       = nonsensitive(module.cluster.oidc_kubeconfig)
}
