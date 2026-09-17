# The estate's names — served here, by the router.
#
# Why internal resolution lives on the router and not in the public zone, both measured:
#
#   1. The public zone carries a `*.hnatekmar.dev` wildcard that answers **every** name with the ingress
#      VIP: `anything.lab.hnatekmar.dev` resolves to `172.16.100.15` from a public resolver. So a client
#      that is not using this resolver gets the ingress VIP for an internal name — right only by accident,
#      and never for a host. This resolver is what makes the class sub-zones mean anything.
#   2. Internal names must resolve when the WAN is down. A public record cannot.
#
# Naming: one sub-zone per class (mgmt / srv / lab / iot / vpn), so a hostname states the plane a host
# belongs to — the same information its address carries (`172.16.30.x` is lab). Machines are
# `<host>.<class>`; services are `<service>.srv`. A record states the class a host is *intended* for;
# **its address is its DHCP reservation's** (`dhcp.tf`), so the name follows the host when it moves and
# nothing that references the name has to change.
#
# Records are not access control. Everything here resolves; the firewall matrix decides who may reach what.
# `iot` is deliberately absent: it keeps public DNS, so that class cannot resolve internal names at all.
# ---------------------------------------------------------------------------
resource "routeros_ip_dns" "resolver" {
  allow_remote_requests = true
  servers               = ["8.8.8.8", "1.1.1.1"]
  # Safe to enable: the router's input chain drops everything that is not from the LAN (defconf), so this
  # does not become an open resolver on the WAN side. See docs/dns.md.
}

locals {
  # The estate's inventory, as names. **DHCP owns the addresses**: a host that has a reservation in
  # `dhcp.tf` reads its address from `local.dhcp_reservations` here, so an address is stated in one
  # place and the name cannot drift from the lease. Only hosts with no reservation — statically
  # addressed infrastructure, and aliases — keep a literal.
  #
  # `minio` is the Terraform state backend: using this name instead of the public one is what removes
  # the WAN hairpin every plan and apply currently takes (docs/dns.md).
  dns_records = {
    # mgmt — the plane that administers
    "router.mgmt.hnatekmar.dev"      = "172.16.10.1"
    "crs326.mgmt.hnatekmar.dev"      = "172.16.10.2"
    "charon.mgmt.hnatekmar.dev"      = "172.16.10.200"
    "crs804.mgmt.hnatekmar.dev"      = local.dhcp_reservations["crs804"].address
    "bmc-balteus.mgmt.hnatekmar.dev" = local.dhcp_reservations["balteus-ipmi"].address
    "runner.mgmt.hnatekmar.dev"      = local.dhcp_reservations["runner"].address
    # The operator host (vault, WebUI, admin box) — re-classed to mgmt, so its name states that class.
    "personal-hermes.mgmt.hnatekmar.dev" = local.dhcp_reservations["personal-hermes"].address

    # srv — the keepers. They have moved into their class, and the reservation now owns the number, so
    # each record follows the lease instead of restating it.
    "truenas.srv.hnatekmar.dev"            = local.dhcp_reservations["truenas"].address
    "minio.srv.hnatekmar.dev"              = local.dhcp_reservations["truenas"].address
    "gitea.srv.hnatekmar.dev"              = local.dhcp_reservations["gitea"].address
    "github-dind.srv.hnatekmar.dev"        = local.dhcp_reservations["github-dind"].address
    "coder.srv.hnatekmar.dev"              = local.dhcp_reservations["coder"].address
    "kubernetes-sandbox.srv.hnatekmar.dev" = local.dhcp_reservations["kubernetes-sandbox"].address
    "stories-hermes.srv.hnatekmar.dev"     = local.dhcp_reservations["stories-hermes"].address
    "sister-hermes.srv.hnatekmar.dev"      = local.dhcp_reservations["sister-hermes"].address

    # The dev cluster. Node names keep the class suffix: the firewall matrix and the diagrams read off the
    # name, so `dev-cp1.srv` states its own VLAN and nobody has to look it up.
    # `dev-k8s` is the *alias* cluster configs and kubeconfigs point at instead of a node: today it
    # resolves to the single control plane, and when there are three (or a service VIP from the reserved
    # `172.16.48.0/20`) it moves there without touching a single cluster — the same late binding the
    # public wildcard uses. A second cluster repeats the shape with its own alias.
    "dev-cp1.srv.hnatekmar.dev" = local.dhcp_reservations["dev-cp1"].address
    "dev-w1.srv.hnatekmar.dev"  = local.dhcp_reservations["dev-w1"].address
    "dev-k8s.srv.hnatekmar.dev" = local.dhcp_reservations["dev-cp1"].address

    # `adonai` — the k3s management host the CAPMOX spike runs on (`spike/capmox-talos`), VMID 144 on
    # balteus. The record follows its reservation, like every other host that has one, so the name and the
    # claim on the address cannot drift apart.
    "adonai.srv.hnatekmar.dev" = local.dhcp_reservations["adonai"].address

    # The box at `.30` — the estate's **reverse proxy**, and more behind it. Measured on the host: Caddy
    # terminates TLS on 80/443 and is published to the WAN by dstnat; authentik + postgres + redis run
    # behind it as the identity provider; and `lmproxy` behind it routes this agent's model traffic to the
    # inference backends — which is why a request for `proxy.personal-hermes.hnatekmar.dev` lands on the
    # LLM router. It also holds a storage-fabric address (`192.168.88.64`), which answers the open
    # question of who else lives on that L2. Both names point at the same host deliberately: `proxy` is
    # its hostname, `edge` is the role.
    #
    # Class note: a reverse proxy facing the internet is the DMZ tier, while the identity store and the
    # model router behind it are keepers — so this one host plays both roles. Because it *is* a reverse
    # proxy, its backends can live elsewhere, so splitting them (proxy in lab, keepers in srv) is a
    # rearrangement rather than a rebuild.
    "proxy.srv.hnatekmar.dev" = local.dhcp_reservations["proxy"].address
    "edge.srv.hnatekmar.dev"  = local.dhcp_reservations["proxy"].address

    # lab — the DMZ-shaped workload zone; the Sparks and the inference host live here already, and
    # their reservations are the addresses the inference path is written against.
    "inference.lab.hnatekmar.dev" = local.dhcp_reservations["inference"].address
    "spark1.lab.hnatekmar.dev"    = local.dhcp_reservations["spark1"].address
    "spark2.lab.hnatekmar.dev"    = local.dhcp_reservations["spark2"].address
    "spark3.lab.hnatekmar.dev"    = local.dhcp_reservations["spark3"].address
    "spark4.lab.hnatekmar.dev"    = local.dhcp_reservations["spark4"].address
  }
}

resource "routeros_ip_dns_record" "estate" {
  for_each = local.dns_records

  name    = each.key
  type    = "A"
  address = each.value
  # Short on purpose while the estate migrates: addresses change as hosts are tagged into their class and
  # a client should pick that up in minutes, not hours. Raise it once the carve is done.
  ttl     = "5m"
  comment = "${local.managed_by} — internal name"
}
