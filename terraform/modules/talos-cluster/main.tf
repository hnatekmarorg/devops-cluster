# Wiring: clone the VMs, generate the configs, apply them, bootstrap, and hand back the artifacts that
# other systems need (the kubeconfig, the join config, the CA and reviewer token for the vault).

# ---------------------------------------------------------------- 0. cluster identity / secrets
# NOTE: this resource puts cluster secrets in the state. Keep the backend private and treat the state
# bucket as secret material, or move the secrets to SOPS and feed them in as a variable.
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

# The config handed to clones the factory did not create — Karpenter's burst workers. The output
# `join_config` references THIS, and it referenced a data source that did not exist, so `tofu validate`
# failed and the join Secret had to be assembled by hand. Keep it a separate data source rather than
# reusing `worker`: the clone contract is different in one way that matters.
#
#   It must NOT pin a hostname. The clones are named by Karpenter, and the CCM requires the VM name to
#   start with the node name — which is satisfied because the provider templates
#   `local-hostname: {{ .Hostname }}` into the cloud-init metadata and Talos's nocloud platform reads it.
#   A HostnameConfig `auto:` value does not get in the way (automatic hostnames have the LOWEST priority
#   against cloud-init), but an explicit `hostname:`, or a --hostname-override kubelet flag, would pin
#   every clone to one name. So nothing per-node may be baked in here.
data "talos_machine_configuration" "join" {
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for n in local.controlplanes : n.address]
  nodes                = [for n in var.nodes : n.address]
}

# ---------------------------------------------------------------- 1. the VMs
# Everything below this line is the clone. The template supplies the base image; the factory supplies
# the identity (name, MAC), the shape, and the network tag.
resource "proxmox_virtual_environment_vm" "node" {
  for_each = { for n in var.nodes : n.name => n }

  name      = each.key
  node_name = var.proxmox_node
  tags      = ["talos", var.cluster_name, each.value.role]
  started   = true
  on_boot   = false

  # The schematic carries qemu-guest-agent; Proxmox needs it enabled to report the guest's addresses,
  # which is how the CCM correlates a node to its VM.
  agent {
    enabled = true
  }

  # Explicit, not inherited: Talos panics on the default kvm64 CPU type.
  cpu {
    cores = each.value.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = each.value.memory_mb
  }

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  # Sized here rather than in the template, so one template serves every shape.
  disk {
    datastore_id = var.template_storage
    interface    = "scsi0"
    size         = each.value.disk_gb
  }

  # The VLAN tag is declared EXPLICITLY. Karpenter's clones inherit it from the template instead, so the
  # two must agree — a mismatch shows up as nodes that boot but can never reach the cluster.
  network_device {
    bridge      = var.bridge
    mac_address = each.value.mac
    vlan_id     = var.vlan_id
  }
}

# The API has to be up before a config can be applied; the provider retries, but this keeps the first
# attempts from being wasted.
resource "time_sleep" "wait_for_boot" {
  depends_on      = [proxmox_virtual_environment_vm.node]
  create_duration = var.boot_wait
}

# ---------------------------------------------------------------- 2. the machine configs
resource "talos_machine_configuration_apply" "node" {
  for_each = { for n in var.nodes : n.name => n }

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = each.value.role == "controlplane" ? data.talos_machine_configuration.controlplane.machine_configuration : data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.address
  # Per node: the kubelet patch carries that node's hostname-override, so this can no longer be two
  # shared lists keyed off the role.
  config_patches = local.patches[each.key]

  # Applied at apply time rather than baked at generation — which is what makes the by-kind patches in
  # patches.tf valid (a generated config cannot carry a second KubeletConfig document).
  timeouts = {
    create = var.apply_timeout
  }

  depends_on = [time_sleep.wait_for_boot]
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplanes[0].address

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplanes[0].address

  depends_on = [talos_machine_bootstrap.this]
}

# The readiness gate: without it, everything downstream races the cluster coming up.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for n in local.controlplanes : n.address]
  control_plane_nodes  = [for n in local.controlplanes : n.address]
  worker_nodes         = [for n in local.workers : n.address]

  depends_on = [talos_machine_bootstrap.this]
}
