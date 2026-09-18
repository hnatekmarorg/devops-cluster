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
  }))

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) >= 1
    error_message = "At least one node must have role = \"controlplane\"."
  }
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
    NTP servers. Talos defaults to time.cloudflare.com, which these VLANs cannot reach — the visible
    symptom is `time query error ... network is unreachable` and, because TLS needs a sane clock,
    every later step failing for unrelated-looking reasons. Point it at the router.
  EOT
  type        = list(string)
  default     = ["172.16.40.1"]
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

variable "join_secret_name" {
  description = "Secret (kube-system) that will hold the worker join config, key `user-data`. Karpenter's NodeClass reads it."
  type        = string
  default     = "karpenter-talos-join"
}

variable "install_vault_reviewer" {
  description = <<-EOT
    Create a `vault-reviewer` service account, its long-lived token and the auth-delegator binding, so the
    on-prem vault can authenticate this cluster's ESO via the `kubernetes` auth method. The CA and the
    token are exported for the vault-side configuration.
  EOT
  type        = bool
  default     = true
}
