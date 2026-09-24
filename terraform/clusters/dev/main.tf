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
      # 8 cores and 16 GiB, not the 4/8 this declared before. This node is the whole control plane (etcd,
      # apiserver, scheduler, controller-manager, CCM, Karpenter) AND the monitoring stack — Prometheus,
      # Grafana, Alertmanager, the operator and kube-state-metrics all live here. Measured 2026-09-24 on
      # 4 cores: every probe on the node timed out (`context deadline exceeded`, kube-state-metrics'
      # `/livez` answering 503), so the kubelet killed containers that were healthy but starved — 73
      # restarts for kube-state-metrics, 37 for the operator, 26 for Prometheus — and each kill flapped
      # the alert rules watching them. Prometheus used ~1.1 cores against a 200m request at 212k series,
      # and its own rule evaluations were timing out (`PrometheusRuleFailures`, critical). Requests were
      # never the binding constraint here; time-slicing was.
      name      = "dev-cp1"
      role      = "controlplane"
      mac       = "BC:24:11:0D:00:10"
      address   = "172.16.40.100"
      cores     = 8
      memory_mb = 16384
      disk_gb   = 40
      # etcd is fsync-bound, and this is the disk that decides whether the cluster is up.
      #
      # THE TIER SPLIT IS BY ROLE, and that is what makes this a rule rather than a measurement:
      #
      #     control planes -> ssd-fast  (NAS SSD mirror, via the TrueNAS plugin): quiet by construction
      #     node roots     -> local-lvm (the single local NVMe): carries the churn
      #
      # A CP writes almost nothing in steady state. Measured on this node 2026-09-24, idle cluster:
      # 0.17 MB/s and ~10 flushes/s — and that already includes the monitoring stack, which also lives
      # here. So the pressure on this tier is PROVISIONING (a new cluster's install/clone), not the
      # workload, which is the point of putting control planes here at all.
      #
      # What made this the answer (2026-09-24): a 1000-pod run drove Karpenter to clone NODE roots onto
      # `ssd-fast`, and the datastore measured 33.3s flush. Moving the WAL off it kept the cluster up but
      # did NOT fix provisioning — the TrueNAS plugin's broker is in the CLONE path
      # (`broker: no response from upstream`, Storage/Custom/TrueNASPlugin.pm:1389), so clones failed,
      # nodes never registered, Karpenter retried, and it left 13 orphan VMs in 7 minutes. Node roots on
      # a local datastore take that plugin out of the node lifecycle entirely: see the worker below.
      storage = "ssd-fast"
      # No TRIM on etcd's volume, deliberately: reclamation is the NAS' problem, not the write path's.
      discard = "ignore"
    },
    {
      name    = "dev-w1"
      role    = "worker"
      mac     = "BC:24:11:0D:00:11"
      address = "172.16.40.101"
      cores   = 8
      # 8 cores, not 4, and 32 GiB, not the 16 the factory declared: with a single worker everything in
      # the cluster competes for these (argocd, crossplane, cert-manager, forgejo, keycloak, artifactory
      # all schedule here), and it carries the heaviest stateful set — artifactory alone requests 4 GiB.
      # Measured 2026-09-24: 95% of its CPU requests and 258% of its CPU limits, 11.2/16 GiB used with
      # 7.9 GiB of requests. Saturation showed up as probe timeouts on unrelated pods, not OOM. This
      # memory line was 8192 while the VM ran on 16384 — i.e. the next apply would have shrunk a worker.
      memory_mb = 32768
      disk_gb   = 40
      # A worker is the NODE tier: the local NVMe, for two reasons that are both about the same failure.
      #
      # (a) Isolation runs the other way now. The churn device must never be the device holding an etcd
      #     WAL, and with the CP above on ssd-fast, node writes belong here.
      # (b) The TrueNAS plugin is a LIFECYCLE dependency, not merely a performance one. Node roots served
      #     by it put its broker in the clone path, and that broker is what answered `no response from
      #     upstream` under the 1000-pod run — clones failed, nodes never registered, Karpenter retried.
      #
      # local-lvm is a legitimate low-latency tier again: 0.9-1.0ms flush, because the NAS' SLOG no
      # longer shares that device (it did when the 09-23 local-lvm vs ssd-fast comparison was taken, and
      # that comparison is why this field has been wrong in both directions). Its other tenants are
      # near-idle — the NAS VM's own boot disk writes 0.04 MB/s. MEASURE before moving it again.
      storage = "local-lvm"
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
