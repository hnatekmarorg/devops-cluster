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
      #     control planes -> ssd-local (a dedicated local thin pool): fast AND independent of the NAS
      #     workers        -> ssd-fast  (NAS SSD mirror, via the TrueNAS plugin): quiet, and redundant
      #     node roots     -> local-lvm (the single local NVMe): carries the churn
      #
      # A CP writes almost nothing in steady state. Measured on this node 2026-09-24, idle cluster:
      # 0.17 MB/s and ~10 flushes/s — and that already includes the monitoring stack, which also lives
      # here. So the pressure on this tier is PROVISIONING (a new cluster's install/clone), not the
      # workload, which is the point of putting control planes here at all.
      #
      # Why ssd-local and not ssd-fast (2026-09-25): a NAS rebuild stopped this VM, because its disk was
      # on the NAS-backed plugin store. Worse, that store's API key was unauthorised (its TrueNAS user had
      # no privileges), so pvestatd's status cycle went from 10s to 346s, EVERY storage reported `unknown`,
      # and the provider — which accepts only storages it sees as available — found no zones:
      # InstanceTemplateReady=False, NodePool not-ready, provisioning stopped completely. A hard stop that
      # looks like nothing from inside the cluster; the fix was one group membership on the NAS.
      #
      # Role, not ranking, still decides this: the CP's disk must be local so that no NAS event can end it,
      # and it must not share a device with the churn. Measured on ssd-local 2026-09-25: 0.66ms average
      # flush against 1.4ms on ssd-fast. Its own 500GB SSD is the one device with nothing else on it.
      storage = "ssd-local"
      # No TRIM on etcd's volume, deliberately: it is 40G on a 450G pool that this VM never grows past, and
      # discard on a thin volume injects latency spikes into the write path for space that is not needed.
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
      # A worker sits on ssd-fast, and the reasoning is the mirror image of the CP's above.
      #
      # (a) It is the QUIET tier. What broke this store was the churn — a 1000-pod run drove Karpenter to
      #     clone NODE roots onto it and it measured 33.3s flush — and a worker creates none of that. Node
      #     roots moved to local-lvm for that reason (see the chart's pool bootDevice), and they stay there.
      # (b) It is the only REDUNDANT option: ssd-fast is a ZFS mirror of two SSDs, whereas both local tiers
      #     are single devices. A worker's root is long-lived state, so mirroring buys more here than it
      #     does for the CP (rebuildable by the factory) or for node roots (ephemeral by design).
      # (c) It is not a new dependency CLASS: this worker's persistent volumes are on truenas-nvmeof
      #     already, so the NAS is in its data path whichever device its root lives on.
      #
      # Accepted cost, stated plainly: a NAS restart or plugin outage takes this worker down — it did on
      # 2026-09-25, when the VM ended up stopped — and pods with NAS-backed PVCs cannot reschedule until
      # the NAS returns. That is a worker-sized blast radius rather than a control-plane one, which is why
      # the CP moved off this store in the same change. local-lvm is still a legitimate tier in its own
      # right (0.9-1.0ms flush once the NAS' SLOG stopped sharing that device), and this field has been
      # wrong in both directions before: MEASURE before moving it again.
      storage = "ssd-fast"
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
