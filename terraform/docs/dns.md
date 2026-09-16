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
| `<host>.<class>.hnatekmar.dev` | `spark1.lab.hnatekmar.dev` | machines, in `mgmt` / `srv` / `lab` / `iot` / `vpn` |
| `<service>.srv.hnatekmar.dev` | `gitea.srv.hnatekmar.dev` | services, which belong to a class by definition |

A record states the class a host is **intended** for. While the estate migrates, the address may still be
the old one; only the address changes when the host moves, and nothing that references the name has to
change. `ttl` is deliberately short (`5m`) until the carve is done.

**`iot` has no records and keeps public DNS.** That class must not be able to resolve an internal name,
which makes resolution itself a class boundary. The exception is deliberate, not an oversight.

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
