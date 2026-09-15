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
# `<host>.<class>`; services are `<service>.srv`. A record states the class a host is *intended* for:
# while the estate migrates, the address may still be the old one, and only the address changes when the
# host moves — which is the entire point of naming them.
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
  # The estate's inventory, as names. `minio` is the Terraform state backend: using this name instead of
  # the public one is what removes the WAN hairpin every plan and apply currently takes (docs/dns.md).
  dns_records = {
    # mgmt — the plane that administers
    "router.mgmt.hnatekmar.dev"      = "172.16.10.1"
    "crs326.mgmt.hnatekmar.dev"      = "172.16.10.2"
    "crs804.mgmt.hnatekmar.dev"      = "172.16.10.201"
    "bmc-balteus.mgmt.hnatekmar.dev" = "172.16.10.46"
    "charon.mgmt.hnatekmar.dev"      = "172.16.10.200"
    "runner.mgmt.hnatekmar.dev"      = "172.16.10.140"

    # srv — the keepers. Addresses are still compat-side where the host has not moved yet.
    "truenas.srv.hnatekmar.dev"            = "172.16.100.148"
    "minio.srv.hnatekmar.dev"              = "172.16.100.148"
    "gitea.srv.hnatekmar.dev"              = "172.16.100.124"
    "github-dind.srv.hnatekmar.dev"        = "172.16.100.145"
    "coder.srv.hnatekmar.dev"              = "172.16.100.210"
    "kubernetes-sandbox.srv.hnatekmar.dev" = "172.16.100.111"
    "personal-hermes.srv.hnatekmar.dev"    = "172.16.100.180"
    "stories-hermes.srv.hnatekmar.dev"     = "172.16.100.188"
    "sister-hermes.srv.hnatekmar.dev"      = "172.16.100.203"

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
    "proxy.srv.hnatekmar.dev" = "172.16.100.30"
    "edge.srv.hnatekmar.dev"  = "172.16.100.30"

    # lab — the DMZ-shaped workload zone; the Sparks and the inference host live here already
    "inference.lab.hnatekmar.dev" = "172.16.30.189"
    "spark1.lab.hnatekmar.dev"    = "172.16.30.136"
    "spark2.lab.hnatekmar.dev"    = "172.16.30.137"
    "spark3.lab.hnatekmar.dev"    = "172.16.30.112"
    "spark4.lab.hnatekmar.dev"    = "172.16.30.110"
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
