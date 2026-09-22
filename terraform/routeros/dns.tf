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
# Naming: one sub-zone per class (mgmt / srv / lab / storage / iot / vpn), so a hostname states the plane
# a host belongs to — the same information its address carries (`172.16.30.x` is lab). Machines are
# `<host>.<class>`; services are `<service>.srv`. A record states the class a host is *intended* for;
# **its address is its DHCP reservation's** (`dhcp.tf`), so the name follows the host when it moves and
# nothing that references the name has to change. Where a host's address in a class is not served by this
# router — the storage fabric's statically addressed NAS — the record carries a literal and says why.
#
# Records are not access control. Everything here resolves; the firewall matrix decides who may reach what.
# `iot` is deliberately absent: it keeps public DNS, so that class cannot resolve internal names at all.
# ---------------------------------------------------------------------------
resource "routeros_ip_dns" "resolver" {
  allow_remote_requests = true
  servers               = ["8.8.8.8", "1.1.1.1"]
  # Safe to enable: the router's input chain drops everything that is not from the LAN (defconf), so this
  # does not become an open resolver on the WAN side. See docs/agent/dns.md.
}

locals {
  # The estate's inventory, as names. **DHCP owns the addresses**: a host that has a reservation in
  # `dhcp.tf` reads its address from `local.dhcp_reservations` here, so an address is stated in one
  # place and the name cannot drift from the lease. Only hosts with no reservation — statically
  # addressed infrastructure, and aliases — keep a literal.
  #
  # `minio` is the Terraform state backend: using this name instead of the public one is what removes
  # the WAN hairpin every plan and apply currently takes (docs/agent/dns.md).
  dns_records = {
    # mgmt — the plane that administers
    "router.mgmt.hnatekmar.dev" = "172.16.10.1"
    "crs326.mgmt.hnatekmar.dev" = "172.16.10.2"
    # Follows its reservation since 2026-09-20: the address was a dynamic `dhcp-mgmt` pool lease while
    # this record carried the literal, which made the name a claim on an address nobody owned (and the
    # address a firewall identity — see `stories-access.tf`, where a `stories_allow_charon` keyed on it
    # would have followed whatever device the pool handed it to).
    "charon.mgmt.hnatekmar.dev"      = local.dhcp_reservations["charon"].address
    "crs804.mgmt.hnatekmar.dev"      = local.dhcp_reservations["crs804"].address
    "crs317.mgmt.hnatekmar.dev"      = local.dhcp_reservations["crs317"].address
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

    # The prod cluster. Same shape as dev's, including the alias: `prod-k8s` is what its configs and
    # kubeconfigs point at, so moving the endpoint off a single node (today it resolves to cp1) does not
    # touch the cluster. NOTE for review: with three control planes the endpoint SHOULD be a VIP
    # (`172.16.48.0/20` is reserved for exactly that), which is not implemented yet — until it is, losing
    # `prod-cp1` takes the API endpoint with it even though the other two keep etcd alive. See the scope
    # list in the cluster PR.
    "prod-cp1.srv.hnatekmar.dev" = local.dhcp_reservations["prod-cp1"].address
    "prod-cp2.srv.hnatekmar.dev" = local.dhcp_reservations["prod-cp2"].address
    "prod-cp3.srv.hnatekmar.dev" = local.dhcp_reservations["prod-cp3"].address
    "prod-w1.srv.hnatekmar.dev"  = local.dhcp_reservations["prod-w1"].address
    "prod-k8s.srv.hnatekmar.dev" = local.dhcp_reservations["prod-cp1"].address
    # The on-prem vault. Two labels under the apex on purpose: `*.hnatekmar.dev` matches exactly one, so
    # this name resolves on the LAN and nowhere else — which is the correct blast radius for it, since
    # only in-estate consumers (ESO with `kubernetes` auth, hosts with approle) and the operator use it.
    "bao.srv.hnatekmar.dev" = local.dhcp_reservations["openbao"].address

    # `adonai` — the k3s management host the CAPMOX spike runs on (`spike/capmox-talos`), VMID 144 on
    # balteus. The record follows its reservation, like every other host that has one, so the name and the
    # claim on the address cannot drift apart.
    "adonai.srv.hnatekmar.dev" = local.dhcp_reservations["adonai"].address

    # `iot` gets a name only where the rest of the estate has to say the device, and the reader is the
    # first: named for the role the firewall already gives it, so lease, rule and name all say the same
    # word. The NAS is *not* named in this sub-zone even though it has an interface here: it is reached by
    # the name of the plane that serves it, `truenas.srv.hnatekmar.dev`, and a second name for the same
    # services would only be a second way to be wrong.
    "reader.iot.hnatekmar.dev" = local.dhcp_reservations["reader"].address

    # The second: the work Mac (`mac-dev` in `dhcp.tf`, `ether3`). It is the one machine in iot that is
    # reached *into* — mgmt ssh/VNC to it, and the port flip is only verified by somebody getting there —
    # so the name exists for the other direction, not for the device. It follows its reservation for the
    # reason the reservation exists: a static lease holds the address out of dynamic assignment, so the
    # name resolves to the address that is *claimed* rather than to whatever the pool last handed out.
    #
    # What this record deliberately does not do is make the name resolve *on* the Mac: iot is handed
    # `8.8.8.8` and may not ask the router (docs/agent/dns.md), so the device cannot resolve even its own name.
    # A `dig` from the Mac proves nothing about this entry. As the header says, a record is not access
    # control either — everything here resolves for any client that can reach the resolver, and the
    # firewall matrix decides who may then reach `172.16.70.116`.
    "mac-dev.iot.hnatekmar.dev" = local.dhcp_reservations["mac-dev"].address

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

    # storage — the air-gapped 10G fabric: the CRS317 island, `192.168.88.0/24`, jumbo 9000, no gateway
    # by design. Its own class because the *plane* is what the name has to state: `truenas.srv` is the
    # management address (`172.16.40.148`, 1G — the API and the UI), while `truenas.storage` is the fabric
    # one, and a storage client must use the latter. Both the iSCSI portal and the NVMe-oF port are bound
    # to `.88.25`, but the same services also listen on the 1G management address (measured: 3260/2049/445
    # answer there from VLAN 40), so a client that resolves the wrong name silently consumes storage over
    # 1G instead of failing.
    #
    # A literal, unlike every other machine record here: the addresses this module owns are the ones the
    # router hands out, and the island's DHCP belongs to the CRS317 (`dhcp1`) — a device deliberately not
    # in IaC, so there is no lease for the name to follow. The NAS's fabric address is static on the
    # appliance itself (`enp6s20`, MTU 9000), which stays its source of truth; this record names it so
    # clients can be written against the name rather than the number.
    "truenas.storage.hnatekmar.dev" = "192.168.88.25"
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

# ---------------------------------------------------------------------------
# The dev cluster's *service* names — one wildcard, so a service gets a name by being deployed rather
# than by an edit here. `.srv` because the nodes are srv-class; `dev-k8s` is the cluster alias.
#
# A REGEXP record, not a plain one: RouterOS has no `*` wildcard for static DNS (an entry that does not
# conform to DNS naming standards is *treated as a regex*, per the docs), and the regex list is matched
# BEFORE the plain records above. That ordering is why the leading label is spelled out and both ends are
# anchored — the bare `dev-k8s.srv.hnatekmar.dev` record above is the API endpoint every kubeconfig
# points at, and a looser pattern (`.*`, or no `$`) would match it and move the API to the ingress VIP.
#
# The address is the dev cluster's ingress VIP: the first address of its /24 out of the estate's reserved
# VIP block (172.16.48.0/20). The pool itself is declared in the cluster's GitOps values
# (charts/cluster-base, `metallb.pool`) — this record is the LAN's view of the same fact.
#
# One consequence worth knowing: these names resolve HERE and upstream does not know them, so a client
# that does not use this resolver falls through to the public `*.hnatekmar.dev` wildcard and gets the
# reverse proxy's address instead. That is the design (internal names resolve internally), but it means
# "it resolves" is not by itself evidence that the client is on the right path.
resource "routeros_ip_dns_record" "dev_cluster_services" {
  # Escaped dots on purpose: an un-escaped dot is a single-character wildcard in a regex, and a match
  # here is a match for a name the API or a host may also be using.
  # `regexp` carries the pattern itself and is mutually exclusive with `name` (the provider enforces
  # one-of), which is how RouterOS stores it too: the regex IS the entry.
  regexp  = "^.+\\.dev-k8s\\.srv\\.hnatekmar\\.dev$"
  type    = "A"
  address = "172.16.48.1"
  ttl     = "5m"
  comment = "${local.managed_by} — the dev cluster's service names (ingress VIP)"
}

# ---------------------------------------------------------------------------
# The prod cluster's *service* names — the same shape as dev's above, and the same reasoning for both the
# regexp form and the leading label. What differs is the alias and the address: `prod-k8s`, and 172.16.49.1
# as the first address of this cluster's /24 out of the reserved 172.16.48.0/20.
#
# Added with the monitoring stack, because `grafana.prod-k8s.srv.hnatekmar.dev` is the first internal
# service name on this cluster that is meant to be opened in a browser. Without this record the name falls
# through to the public `*.hnatekmar.dev` wildcard and answers 172.16.100.15 — the reverse proxy, which
# does not serve this cluster and cannot, since the LAN name is what carries the cluster's certificate.
# The failure that produces is a login page that loads from the wrong host or not at all, which reads like
# an ingress or SSO fault rather than a missing record.
resource "routeros_ip_dns_record" "prod_cluster_services" {
  regexp  = "^.+\\.prod-k8s\\.srv\\.hnatekmar\\.dev$"
  type    = "A"
  address = "172.16.49.1"
  ttl     = "5m"
  comment = "${local.managed_by} — the prod cluster's service names (ingress VIP)"
}
