# The factory's contract. A new cluster should be about twenty lines of inputs — everything that is
# genuinely the same across clusters is defaulted here, and everything that cost time to learn is either
# defaulted or defaulted-with-a-comment.

# ---------------------------------------------------------------- identity

variable "cluster_name" {
  description = "Short cluster name, e.g. `dev`. Used in resource names and as the state key."
  type        = string
}

variable "cluster_endpoint" {
  description = <<-EOT
    The address every node's config advertises as the Kubernetes API, e.g.
    `https://dev-k8s.srv.hnatekmar.dev:6443`. For a single control plane this is that node's name; for
    three it is a VIP from 172.16.48.0/20.
  EOT
  type        = string
}

variable "talos_version" {
  description = "Talos release, e.g. v1.14.1. Pin it: the version decides whether a raft snapshot or an upgrade path is compatible."
  type        = string
  default     = "v1.14.1"
}

variable "kubernetes_version" {
  description = "Kubernetes version Talos should run. null = whatever the Talos release defaults to."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- the image

variable "talos_schematic_id" {
  description = <<-EOT
    Factory schematic ID. It must include `siderolabs/qemu-guest-agent` or Proxmox cannot read the
    guest's addresses — which the CCM needs to correlate a node to its VM.
  EOT
  type        = string
}

variable "install_image" {
  description = <<-EOT
    The installer image used when a node installs itself. Leave null to derive
    `factory.talos.dev/nocloud-installer/<schematic>:<version>`.

    **nocloud, not metal.** The stock `UnattendedInstallConfig` inherits `machine.install.image`, whose
    default is the *metal* installer — wrong platform for these VMs, and the reason an install attempt
    originally failed. Set explicitly if you ever pin a digest.
  EOT
  type        = string
  default     = null
}

variable "install_disk" {
  description = "Disk Talos installs to inside the VM. virtio-scsi gives /dev/sda."
  type        = string
  default     = "/dev/sda"
}

# ---------------------------------------------------------------- Proxmox

variable "proxmox_node" {
  description = "Proxmox node the VMs run on, e.g. `balteus`."
  type        = string
}

variable "template_vm_id" {
  description = <<-EOT
    The PVE template every node is cloned from. The template must already carry the class VLAN tag on its
    NIC and cpu=x86-64-v2-AES, and must live on ONE storage — a cloud-init drive on a second storage
    gives `Multiple storage IDs found for template`.
  EOT
  type        = number
}

variable "template_storage" {
  description = "The storage the template lives on; also where clone disks are created."
  type        = string
  default     = "iscsi"
}

variable "bridge" {
  description = "The Proxmox bridge the cloned NICs attach to. The VLAN tag comes from the template."
  type        = string
  default     = "vmbr0"
}

# ---------------------------------------------------------------- the nodes

variable "nodes" {
  description = <<-EOT
    The static nodes. MAC addresses come from the router's DHCP reservations (`dhcp.tf`), because the
    estate's rule is that a name follows its reservation — so a cluster provisioned twice lands on the
    same addresses both times. `address` is the reserved address: the factory needs it up front, because
    the machine config is applied over the network rather than discovered.
  EOT
  type = list(object({
    name      = string
    role      = string # "controlplane" | "worker"
    mac       = string
    address   = string
    cores     = number
    memory_mb = number
    disk_gb   = number
    # Where this node's disk lives. Defaults to template_storage (iscsi) when unset.
    #
    # SET IT TO LOCAL STORAGE FOR CONTROL PLANES. etcd's write path is fsync-bound, and on network block
    # storage that latency is measurable: on the dev cluster's CP (disk on iscsi, LVM over iSCSI)
    #
    #   etcd: "apply request took too long"  took=118ms / 138ms / 350ms   (expected-duration 100ms)
    #   apiserver -> etcd-client: "rpc error: code = Unavailable desc = etcdserver: request timed out"
    #
    # and once the API cannot answer for longer than a lease deadline, EVERY lease holder exits at once:
    # kube-controller-manager, kube-scheduler, the CCM and Karpenter (which panics with
    # "leader election lost"). The visible damage is a half-built VM — Karpenter had cloned it, then died
    # before resizing the disk, attaching the cloud-init ISO and starting it.
    #
    # Workers are the opposite case: images want space, and a worker losing its API connection does not take
    # the cluster with it, so they stay on iscsi.
    storage = optional(string)

    # MAC for the second (storage) NIC, used only when `storage_bridge` is set. Leave null and Proxmox
    # generates one: the island runs DHCP, so it does not need a reservation, and a reservation on a MAC
    # that PVE regenerates at clone time would be worse than none.
    storage_mac = optional(string)
  }))

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) >= 1
    error_message = "At least one node must have role = \"controlplane\"."
  }
}

variable "storage_bridge" {
  description = <<-EOT
    The SECOND NIC: the Proxmox bridge carrying the storage LAN — the air-gapped `192.168.88.0/24` island
    (`vmbr2` on balteus). Null, the default, adds no second NIC.

    Why a cluster wants one: every Kubernetes node is meant to have a 10 Gbps link into the storage
    network, which is where the NAS lives. The island is its own bridge at jumbo MTU, **untagged**, and it
    runs DHCP — so nothing per-node is needed here, because the machine config's interface selector
    already matches every physical NIC (`physical = true`) and asks each one for DHCP.

    ORDER IS LOAD-BEARING, which is why this is a second `network_device` block rather than a list input:
    Proxmox names the interfaces net0, net1, … in declaration order, and the class VLAN tag belongs on
    net0.

    Applying this to a RUNNING node adds the device to the VM, but the guest only sees it after a reboot —
    Talos enumerates network interfaces at boot. That is the one-off cost of moving an existing cluster
    onto the storage network.
  EOT
  type        = string
  default     = null
}

variable "storage_mtu" {
  description = "MTU for the storage NIC. The island runs jumbo frames (9000) and the template's net1 says the same; a mismatch shows up as failures that read like a broken NAS rather than a network."
  type        = number
  default     = 9000
}

variable "vlan_id" {
  description = <<-EOT
    The class VLAN tag for the cloned NICs. Declared explicitly here; Karpenter's clones instead inherit
    the tag from the PVE template, so **the template's tag and this must agree** — a mismatch produces
    nodes that boot and never reach the cluster.
  EOT
  type        = number
}

variable "cpu_type" {
  description = "CPU type for cloned VMs. Explicit because the Proxmox default (kvm64) makes Talos panic."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "boot_wait" {
  description = "How long to wait after starting the VMs before applying configs. The provider retries, but the first attempts would otherwise be wasted."
  type        = string
  default     = "45s"
}

variable "apply_timeout" {
  description = "Timeout for applying a machine config to one node. Generous, because a node that installs to disk reboots mid-apply."
  type        = string
  default     = "20m"
}

# ---------------------------------------------------------------- node behaviour

variable "time_servers" {
  description = <<-EOT
    NTP servers. Point these at a source that ANSWERS — measured 2026-09-18, udp/123 is unanswered on
    every router address (.1 of each segment), so "point it at the router" is the trap: the earlier
    version of this text said exactly that, and a control-plane reboot then sat for twelve minutes at

      etcd    Waiting  "Waiting for time sync"
      kubelet Waiting  "Waiting for time sync"

    with the k8s API refusing connections — which reads as a broken cluster, not a clock. Talos GATES
    etcd and kubelet on the clock, so an unreachable server is not a warning, it is an outage.

    Note the DHCP option-42 advertisement points at the router too (see the routeros root, where
    ntp_none stops it). Public NTP is reachable from these VLANs and is the working choice.
  EOT
  type        = list(string)
  # NOT the router, which is what this used to default to. udp/123 is unanswered on every router
  # address (measured across all five), so a router default builds clusters that hang at "Waiting for
  # time sync" — which the previous 172.16.40.1 did, on a control-plane reconnect.
  default = ["time.cloudflare.com", "216.239.35.0"]
}

variable "network_interface_selector" {
  description = <<-EOT
    Which NIC to bring up, as a Talos device selector.

    Talos on the nocloud platform does NOT assume DHCP: with no interface declared the guest boots with no
    address at all and every log line says `network is unreachable`, while looking healthy from the host
    side. Declaring it is mandatory and invisible in any Proxmox-side manifest.
  EOT
  type = object({
    physical = optional(bool, true)
    name     = optional(string, null)
  })
  default = { physical = true }
}

variable "kubelet_extra_args" {
  description = <<-EOT
    Kubelet flags. `cloud-provider=external` is required whenever the Proxmox CCM runs: it is what makes
    the kubelet publish `alpha.kubernetes.io/provided-node-ip` and mark the node for initialisation, which
    is how the CCM learns a node's providerID. Without it NodeClaims never register and Karpenter
    terminates instances it has just built.
  EOT
  type        = map(string)
  default     = { "cloud-provider" = "external" }
}

variable "cert_sans" {
  description = "Extra certificate SANs for the control plane, on top of the endpoint and node names."
  type        = list(string)
  default     = []
}

variable "allow_scheduling_on_control_planes" {
  description = <<-EOT
    Let ordinary pods land on control planes. Right for a small dev cluster; wrong for anything that
    matters. Note the CCM also assigns taints from VM configuration, so verify the taint state rather
    than assuming this took effect.
  EOT
  type        = bool
  default     = true
}

variable "extra_patches" {
  description = "Additional machine-config patches, applied after the ones above."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- cluster services

variable "set_hostnames" {
  description = <<-EOT
    Whether to patch each node's static hostname. DEFAULTS TO FALSE because it does not work through this
    provider: the generated config already carries a HostnameConfig document and it cannot be neutralised
    by a patch (see patches.tf for the five attempts). With it off, nodes are named `talos-<random>`,
    which is cosmetic — addresses come from the reservations, so DNS still resolves.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- OIDC (Kubernetes user authentication)
# Turning this on makes a credential-free kubeconfig possible: the cluster trusts Keycloak, and users
# authenticate with kubelogin instead of a client certificate.
variable "oidc_enabled" {
  description = "Trust Keycloak for Kubernetes user authentication (structured AuthenticationConfiguration)."
  type        = bool
  default     = false
}

variable "oidc_issuer_url" {
  description = "Keycloak realm issuer. NOTE the path: Keycloak 17+ dropped the /auth prefix."
  type        = string
  default     = "https://sso.hnatekmar.xyz/realms/master"
}

variable "oidc_client_id" {
  description = "The PUBLIC Keycloak client kubelogin authenticates as. Also the expected token audience."
  type        = string
  default     = "kubectl-hnatekmar-xyz"
}

variable "oidc_username_claim" {
  description = "Claim mapped to the Kubernetes username."
  type        = string
  default     = "email"
}

variable "oidc_groups_claim" {
  description = <<-EOT
    Claim carrying cluster-access roles. Defaults to `groups` because the realm propagates the roles
    attached to a user into that array — the estate's existing convention (OpenBao boundGroups, ArgoCD
    group bindings). Binding subjects therefore read `sso:k8s-dev-admin` etc.

NOT realm_access.roles. The structured AuthenticationConfiguration CAN read a nested claim
      (claimMappings.groups.claim = "realm_access.roles" would work), but staying on the top-level array
      keeps this consistent with everything else that binds these roles — OpenBao's boundGroups, ArgoCD's
      group bindings — so there is one documented shape rather than two.

      The note that used to be here cited siderolabs/talos#14394 for the opposite conclusion. That issue
      is about KubeAPIServerConfig missing extraVolumes; it says nothing about claim mappings. What IS true
      on 1.14 is that .cluster.apiServer is deprecated and the API server runs with
      --authentication-config, so an issuer must be declared as a KubeAuthenticationConfig document — which
      this module now does via patches.tf.
  EOT
  type        = string
  default     = "groups"
}

variable "oidc_claim_prefix" {
  description = <<-EOT
    Prefix applied to mapped usernames and groups. Not cosmetic: without it, a Keycloak role named
    system:masters would land verbatim in the token and Kubernetes honours system: prefixed groups,
    silently granting cluster-admin.
  EOT
  type        = string
  default     = "sso:"
}

variable "check_health" {
  description = <<-EOT
    Whether the factory gates on cluster health at apply time.

    DEFAULT TRUE, and set it false to repair a broken cluster. The health data source reads the cluster
    to decide, so when the API server is down a normal apply DEADLOCKS: the check waits for the thing
    being repaired. That happened for real — an invalid OIDC config took the API server down, and the
    revert plan hung on `talos_cluster_health: Still reading...` until it timed out.
  EOT
  type        = bool
  default     = true
}
