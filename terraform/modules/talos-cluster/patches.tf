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
# Note what is deliberately ABSENT: no hostname patch. The stock config carries
# `HostnameConfig: {auto: stable}`, and on the nocloud platform that resolves to the VM's name via the
# instance-id — so naming the VM correctly is enough, and patching the hostname as well only invites the
# legacy/document collision above.

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
  patch_kubelet = length(var.kubelet_extra_args) > 0 ? yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeletConfig"
    extraArgs  = var.kubelet_extra_args
  }) : null

  patch_cert_sans = length(var.cert_sans) > 0 ? yamlencode({
    machine = { certSANs = var.cert_sans }
  }) : null

  patch_scheduling = yamlencode({
    cluster = { allowSchedulingOnControlPlanes = var.allow_scheduling_on_control_planes }
  })

  # control-plane vs worker: only the CP carries certSANs and the scheduling flag
  patches_controlplane = concat(
    compact([
      local.patch_network,
      local.patch_time,
      local.patch_install,
      local.patch_install_trigger,
      local.patch_kubelet,
      local.patch_cert_sans,
      local.patch_scheduling,
    ]),
    var.extra_patches,
  )

  patches_worker = concat(
    compact([
      local.patch_network,
      local.patch_time,
      local.patch_install,
      local.patch_install_trigger,
      local.patch_kubelet,
    ]),
    var.extra_patches,
  )

  controlplanes = [for n in var.nodes : n if n.role == "controlplane"]
  workers       = [for n in var.nodes : n if n.role == "worker"]
}
