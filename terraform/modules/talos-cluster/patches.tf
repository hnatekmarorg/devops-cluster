# The patches — this file is the point of the factory. Each one encodes something that cost hours to find,
# and they are applied at APPLY time (not baked into a generated config), which is what keeps them correct.
#
# THE RULE, discovered the hard way:
#   a LEGACY field collides with its DOCUMENT equivalent, and only then.
#     machine.network.hostname   ⇄ HostnameConfig    (collision)
#     machine.kubelet.extraArgs  ⇄ KubeletConfig     (collision)
#   Fields with no document — machine.install, machine.network.interfaces, machine.time, machine.certSANs,
#   cluster.allowSchedulingOnControlPlanes — merge normally.
#   So: patch the two above as DOCUMENTS (by kind), everything else as plain fields.
#
# THE NODE NAME IS LOAD-BEARING, and it is not the OS hostname.
#   The CCM's getInstanceInfo ends with
#     if !strings.HasPrefix(info.Name, node.Name) { return nil, cloudprovider.InstanceNotFound }
#   where info.Name is the PROXMOX VM name and node.Name is the name the kubelet registered. A rejected
#   instance means no providerID is ever set and node.cloudprovider.kubernetes.io/uninitialized is never
#   cleared, so nothing schedules. Measured on dev: VMs dev-cp1/dev-w1, nodes talos-47c-k0r/talos-oub-c7q.
#
#   The OS hostname CANNOT carry this here. The stock config ships `HostnameConfig: {auto: stable}`, and
#   `auto` conflicts with `hostname` ("'auto' and 'hostname' cannot be set at the same time"), so a patch
#   cannot set one — a strategic merge cannot drop the field either. Worse, `auto: stable` is NOT the VM
#   name: it is a stable hash.
#
#   So the node NAME comes from the kubelet instead: --hostname-override sets what kubelet registers,
#   independent of the OS hostname, and it is per node (see patch_kubelet below). This is also why the
#   factory cannot leave naming to `auto: stable` and hope.

locals {
  install_image = coalesce(var.install_image, "factory.talos.dev/nocloud-installer/${var.talos_schematic_id}:${var.talos_version}")

  # Declaring the interface is MANDATORY on nocloud: with nothing declared the guest boots with no address
  # at all, logging only `network is unreachable`, while looking healthy from the Proxmox side.
  patch_network = yamlencode({
    machine = {
      network = {
        interfaces = [{
          deviceSelector = var.network_interface_selector
          dhcp           = true
        }]
      }
    }
  })

  # Talos defaults to time.cloudflare.com, unreachable from these VLANs. Without a clock, TLS fails and
  # every subsequent step fails for reasons that look unrelated.
  patch_time = yamlencode({
    machine = {
      time = { servers = var.time_servers }
    }
  })

  # Install to disk instead of running from the image. Running from the image means a RAM-backed /var
  # (we measured 2.1 GB of "none" filesystem on a 33 GB disk), which fills under load and taints the node
  # disk-pressure — after which nothing schedules at all.
  patch_install = yamlencode({
    machine = {
      install = {
        disk  = var.install_disk
        image = local.install_image
        wipe  = false
      }
    }
  })

  # The document that actually triggers the install on the nocloud platform. The stock config has it;
  # removing it (to escape the clock problem, as we once did) silently returns the node to the RAM-backed
  # ephemeral filesystem.
  patch_install_trigger = yamlencode({
    apiVersion   = "v1alpha1"
    kind         = "UnattendedInstallConfig"
    diskSelector = { match = "disk.dev_path == \"${var.install_disk}\"" }
    wipe         = false
  })

  # BY KIND. KubeletConfig is a document in this Talos format, so a legacy machine.kubelet patch fails with
  # `kubelet config is already set in v1alpha1 config`.
  #
  # PER NODE, because of hostname-override: the name this kubelet registers MUST be a prefix of the VM
  # name (see the header). The VM is created from var.nodes[].name, so that name is what the node must
  # report. Setting it here rather than as an OS hostname is deliberate — see the header for why a
  # HostnameConfig patch cannot be used.
  patch_kubelet = {
    for n in var.nodes : n.name => yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeletConfig"
      extraArgs  = merge(var.kubelet_extra_args, { "hostname-override" = n.name })
    })
  }

  patch_cert_sans = length(var.cert_sans) > 0 ? yamlencode({
    machine = { certSANs = var.cert_sans }
  }) : null

  patch_scheduling = yamlencode({
    cluster = { allowSchedulingOnControlPlanes = var.allow_scheduling_on_control_planes }
  })

  # PER NODE: the kubelet patch carries that node's hostname-override, so these can no longer be two
  # shared lists. control-plane vs worker still differs: only the CP carries certSANs and the scheduling flag.
  patches = {
    for n in var.nodes : n.name => concat(
      compact([
        local.patch_network,
        local.patch_time,
        local.patch_install,
        local.patch_install_trigger,
        local.patch_kubelet[n.name],
        n.role == "controlplane" ? local.patch_cert_sans : null,
        n.role == "controlplane" ? local.patch_scheduling : null,
      ]),
      var.extra_patches,
    )
  }

  controlplanes = [for n in var.nodes : n if n.role == "controlplane"]
  workers       = [for n in var.nodes : n if n.role == "worker"]
}
