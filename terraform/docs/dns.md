# DNS

Internal names are served by **the router**, in this module. The public zone (`hnatekmar.dev`, at its
provider) keeps serving the ingress names and their certificates, and is not touched by this.

## Why not the public zone

Measured, not argued:

```
nonsense-9x7.hnatekmar.dev   -> 172.16.100.15
anything.lab.hnatekmar.dev   -> 172.16.100.15
```

The public zone carries a `*.hnatekmar.dev` wildcard, so **every** name answers with the ingress VIP.
A client that is not using this resolver therefore gets `172.16.100.15` for an internal name — right only
by accident, and never for a host. On top of that, internal names have to resolve when the WAN is down,
which a public record cannot do.

## The scheme

One sub-zone per class, so a hostname states the plane it belongs to — the same information its address
carries (`172.16.30.x` is lab):

| form | example | for |
|---|---|---|
| `<host>.<class>.hnatekmar.dev` | `spark1.lab.hnatekmar.dev` | machines, in `mgmt` / `srv` / `lab` / `storage` / `iot` / `vpn` |
| `<service>.srv.hnatekmar.dev` | `gitea.srv.hnatekmar.dev` | services, which belong to a class by definition |

A record states the class a host is **intended** for. While the estate migrates, the address may still be
the old one; only the address changes when the host moves, and nothing that references the name has to
change. `ttl` is deliberately short (`5m`) until the carve is done.

## The `storage` class, and why its records are literals

`storage` is the air-gapped 10G fabric — the CRS317 island, `192.168.88.0/24`, jumbo 9000, no gateway by
design. The class exists so the *plane* is sayable in a name: the NAS answers both as
`truenas.srv.hnatekmar.dev` (`172.16.40.148`, 1G management — API, UI) and as
`truenas.storage.hnatekmar.dev` (`192.168.88.25`, 10G), and a storage client has to use the second.
Nothing fails loudly if it does not: iSCSI `3260`, NFS `2049` and SMB `445` also answer on the 1G
management address (measured from VLAN 40), so the wrong name means traffic over the wrong plane rather
than a refused connection.

Every other machine record in `dns.tf` takes its address from a DHCP reservation because the router owns
those addresses. The island's DHCP belongs to the CRS317 (`dhcp1`), which is deliberately not in IaC, and
the addresses clients care about there are static on the hosts themselves (TrueNAS `enp6s20` =
`192.168.88.25`, MTU 9000). So storage records carry a literal and the host remains the source of truth —
same naming scheme, different owner of the number.

**`iot` has records now, and still keeps public DNS.** The boundary is resolution, not naming: the
segment is handed `8.8.8.8` and may not ask the router, so no record in this list makes an internal name
resolvable *inside* iot. What the two `iot` records do is let everything else name the segment —
`reader.iot.hnatekmar.dev` is the reader, whose resolver *is* the router by a per-lease DHCP option (the
one exempted device, see the reader section of the matrix), and `truenas.iot.hnatekmar.dev` is the NAS's
second NIC, a claim and a name rather than a path: the reader reaches SMB on the `srv` address.

**Records are not access control.** Everything in `dns.tf` resolves for any client that can reach the
resolver; the firewall matrix decides who may reach what.

## The resolver

`/ip/dns` with `allow-remote-requests` on. That is safe here because the router's input chain drops
everything that is not from the LAN (the defconf rule), so this does not become an open resolver on the
WAN side. Each class's DHCP scope hands out **the router's address in that class** (`dhcp.tf`), so
resolution never leaves the VLAN; upstream is public DNS (`8.8.8.8`, `1.1.1.1`).

## Follow-ups this enables

- **The Terraform state stops hairpinning.** The endpoint is currently `https://console-minio.hnatekmar.xyz`,
  which resolves to the estate's *WAN* address — every plan and apply leaves the LAN and comes back in
  through the router's NAT. `minio.srv.hnatekmar.dev` is in `dns.tf`; pointing `vars.TF_STATE_ENDPOINT`
  at it removes the hairpin. Do that together with the mgmt runner, since the current ARC runners cannot
  resolve internal names.
- **The runner's record and reservation** (`runner.mgmt.hnatekmar.dev`, `172.16.10.140`) wait for the box
  to exist, since a reservation needs its MAC. Plug it into the router's `ether1`: that port is already a
  mgmt access port (`pvid 10`, admit-only-untagged), so no network change is needed.
- **The `proxy` LXC** has no reservation yet, so it cannot keep a suffix it never had a name for.
- **`172.16.100.15` is load-bearing for the public wildcard.** It is the ingress VIP the wildcard answers
  with, and it sits outside MetalLB's declared pool (`172.16.100.21-172.16.100.29`) — so it is assigned by
  hand somewhere. When the VIP pool moves to `svc-vips`, the wildcard's target has to move with it.
