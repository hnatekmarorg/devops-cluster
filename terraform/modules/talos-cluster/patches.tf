# The patches — this file is the point of the factory. Each one encodes something that cost hours to find,
# and they are applied at APPLY time (not baked into a generated config), which is what keeps them correct.
#
# THE RULE, and the earlier version of it was WRONG. Measured on the first real apply of this module
# against Talos v1.14.1 and provider v0.12.0, where four patches failed one after another:
#
#   a patch is refused when the GENERATED config already sets that field — either as a plain field or as
#   the DOCUMENT equivalent. Talos rejects both forms:
#
#     *.cluster.allowSchedulingOnControlPlanes is already set in v1alpha1 config
#     * UnattendedInstallConfig config is incompatible with v1alpha1 config (.machine.install)
#     * HostnameConfig: 'auto' and 'hostname' cannot be set at the same time
#     * KubeletConfig is already set in v1alpha1 config
#
#   What DOES merge: machine.network.interfaces, machine.time, machine.certSANs (the generated config
#   leaves these alone).
#
#   And the provider's machinery must KNOW a document kind before it can carry it. With provider v0.11.0
#   (the newest stable) `KubeletConfig` and `UnattendedInstallConfig` are simply "not registered", so the
#   by-kind patches below could not even be expressed — hence the provider pin to v0.12.0-rc.0.
#
# So: patch as DOCUMENTS whatever the generated config already sets, as plain fields whatever it does
# not, and check which is which after every Talos or provider bump.
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
  # TALOS CANNOT DECODE A NULL. The selector variable carries an optional `name` that is unset by
  # default, and passing the object straight through renders
  #   deviceSelector: {physical: true, name: null}
  # which Talos refuses outright:
  #
  #   error decoding document /v1alpha1/ (line 1): unknown keys found during decoding:
  #   machine.network.interfaces[0].deviceSelector: name: null
  #
  # The patch is rejected AS A WHOLE, so the machine config is never applied and the node sits in
  # maintenance mode: booted, reachable on :50000, no address, no cluster. Build the selector from the
  # fields that are actually set.
  patch_network = yamlencode({
    machine = {
      network = {
        interfaces = [{
          deviceSelector = merge(
            var.network_interface_selector.physical == null ? {} : { physical = var.network_interface_selector.physical },
            var.network_interface_selector.name == null ? {} : { name = var.network_interface_selector.name },
          )
          dhcp = true
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
  # NOT PATCHED as a legacy field. On Talos v1.14 the generated config already carries an
  # UnattendedInstallConfig document, and Talos rejects having both — measured:
  #
  #   rpc error: code = InvalidArgument desc = 1 error occurred:
  #     * UnattendedInstallConfig config is incompatible with v1alpha1 config (.machine.install)
  #
  # So the disk and the installer image are set on the DOCUMENT instead, by kind — see
  # patch_unattended_install below, which replaces what this used to do.
  patch_install = null

  # NOT APPLIED, and this is a provider limitation rather than a choice.

  #

  # The document that triggers the disk install on nocloud is UnattendedInstallConfig, and its

  # v1.14 shape is nested:

  #

  #   installer:    { image }

  #   provisioning: { diskSelector: { match }, wipe }

  #   reboot

  #

  # The terraform provider (siderolabs/talos v0.11.0, the newest stable — v0.12.0-rc.0 is the only

  # newer release) carries Talos machinery older than that document, so it refuses the patch before

  # Talos ever sees it:

  #

  #   Error: Error loading config patches

  #   error decoding document v1alpha1/UnattendedInstallConfig/ (line 1):

  #   "UnattendedInstallConfig" "v1alpha1": not registered

  #

  # and the flat form it replaced was rejected by the NODE instead

  # ("unknown keys found during decoding: diskSelector ... wipe"). Either way the patch is not applied,

  # so leaving it in fails the apply. machine.install (above) still names the disk and the nocloud

  # installer image — what is missing is the document that TRIGGERS the install.

  #

  # FOLLOW-UP: confirm whether these nodes actually install to disk or run from the RAM-backed image

  # (the author's note: 2.1 GB of "none" filesystem, which fills under load and taints disk-pressure).

  # Two ways to restore it: bump the provider to v0.12.x when it goes stable, or apply the document

  # post-provision with a talosctl that matches the cluster version.

  # THE INSTALL, as the document v1.14 actually uses. Both halves live here: the installer image and

  # the disk it installs to. This replaces the legacy machine.install patch, which v1.14 refuses

  # outright when the generated config already carries this document.

  #

  # The shape is NESTED — installer, and provisioning{diskSelector, wipe} — not flat. The flat form

  # (diskSelector/wipe at the top level) is rejected by the node with "unknown keys found during

  # decoding", and because a decode failure fails the WHOLE config load, a node carrying it boots

  # into maintenance mode and never joins.

  patch_unattended_install = yamlencode({

    apiVersion = "v1alpha1"

    kind = "UnattendedInstallConfig"

    installer = {

      image = local.install_image

    }

    provisioning = {

      diskSelector = { match = "disk.dev_path == \"${var.install_disk}\"" }

      wipe = false

    }

    reboot = false

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

  # NOT PATCHED. The generated v1.14 config already sets cluster.allowSchedulingOnControlPlanes, and a

  # plain-field patch for a field that is already set is refused:

  #

  #   rpc error: code = InvalidArgument desc = 1 error occurred:

  #     * .cluster.allowSchedulingOnControlPlanes is already set in v1alpha1 config

  #

  # The generated default stands. On Talos v1.14 that default is to ALLOW scheduling on control planes,

  # which is what this patch wanted anyway — so the variable is now inert for this Talos version.

  # VERIFY the taint state after provisioning rather than assuming: the CCM can also assign taints from

  # VM configuration.

  patch_scheduling = null

  # For the join config: same kubelet flags, but WITHOUT hostname-override. Every clone would otherwise
  # register under one name. cloud-provider=external must still be here — the CCM needs the kubelet to
  # publish provided-node-ip and mark the node for initialisation.
  patch_kubelet_join = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeletConfig"
    extraArgs  = var.kubelet_extra_args
  })

  # PER NODE: the kubelet patch carries that node's hostname-override, so these can no longer be two
  # shared lists. control-plane vs worker still differs: only the CP carries certSANs and the scheduling flag.
  patches = {
    for n in var.nodes : n.name => concat(
      compact([
        local.patch_network,
        local.patch_time,
        local.patch_unattended_install,
        local.patch_kubelet[n.name],
        n.role == "controlplane" ? local.patch_cert_sans : null,
      ]),
      var.extra_patches,
    )
  }

  controlplanes = [for n in var.nodes : n if n.role == "controlplane"]
  workers       = [for n in var.nodes : n if n.role == "worker"]
}
