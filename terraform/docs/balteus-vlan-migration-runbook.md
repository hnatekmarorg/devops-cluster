# balteus — putting guests into their classes

The switch side is `terraform/crs326/stage2-filtering.tf`; this is the host side, which is hand work
(Proxmox is not managed by this repo). Read it before touching the bond: **the same port carries the
vault's storage path and the Hermes host's own NFS mount.**

## What is true before you start

- The CRS326 carries `balteus` as a **trunk member of every class VLAN** (10 mgmt, 30 lab, 40 srv, 60 vpn,
  70 iot) and the router's uplink carries them all. The bond's port `pvid` is **1**, so the host and every
  guest that is *not* tagged keep living in compat, exactly as today.
- Nothing has moved yet. Making the port a trunk changed nothing on the wire — it only means tagged frames
  are now carried instead of dropped.
- Measured 2026-09-15, from `/cluster/resources`: **35 qemu VMs + 11 LXC = 46 guests**, of which
  **14 qemu and 4 LXC are running**. `vm 101 truenas` is one of the running ones — it is the vault, so it
  is the *last* thing to move, not the first.

## Step 0 — the lifeboat first (zero risk, and it is not where you would guess)

Before anything on the LAN path changes, give the host an address on the **spark storage L2** so a broken
`vmbr0` cannot lock anyone out. Measured topology, 2026-09-15:

| Host side | Carries | Where it leads |
|---|---|---|
| `bond0` (LACP, `enp68s0f0`+`enp68s0f1`) → **`vmbr2`** (`192.168.88.20/24`) | the storage fabric | the CRS804's compute bridge — **the sparks' `192.168.0.x` NICs are on this same L2** |
| `eno1` → **`vmbr0`** (`172.16.100.38/24`, gateway `.100.1`) | the LAN, all 46 guests | the CRS326 (`ether2` — the only live member of its bond) |
| `eno2` → **`vmbr4`** (no address, comment `spark-nas`) | a **direct** link | *not* the shared fabric — nothing on it answers from spark1 |
| `vmbr3` (`192.168.1.2/24`, no ports) | internal | WireGuard |

So the lifeboat goes on **`vmbr2`, not `vmbr4`**. Proof rather than theory: from spark1,
`ping 192.168.0.250` answers *on the same NIC as the other sparks*, and that MAC (`bc:24:11:…`) is a Proxmox
guest — the vault's storage NIC. `vmbr2` is therefore the bridge the sparks can already reach; `vmbr4`'s
cable touches something spark1 cannot see, and it is the truenas ↔ spark storage path you want left alone.

```bash
# in the vmbr2 stanza of /etc/network/interfaces, keep the existing address and add a second one:
#     address 192.168.88.20/24
#     address 192.168.0.38/24        # new: the sparks' subnet, so they can reach us without a router
#     gateway 172.16.100.1           # unchanged — do NOT put a gateway on the fabric subnet
ifreload -a
```

`192.168.0.38` was **free** (checked from spark1: no reply, neighbour entry `FAILED`). Adding a second
address to a bridge is additive — no traffic moves, no interruption. Afterwards, from any spark:
`ssh <user>@192.168.0.38` reaches balteus even if `vmbr0` is down. That is the whole point of it: the
sparks are on the fabric and the fabric is a different NIC with a different cable.

Note the fabric is one L2 carrying several subnets — `192.168.0.x` (sparks, the vault's storage NIC),
`192.168.1.x` (the sparks' second ports) and `192.168.88.x` (this host) — with no router between them. That
is why the lifeboat must be in the *sparks'* subnet: they have no route to `192.168.88.0/24`, so
`192.168.88.20` is unreachable from them (measured).

## Step 1 — make the host bridge VLAN-aware (once)

Proxmox refuses to start a guest with a `tag=` on a bridge that is not VLAN-aware, so this comes first.

```bash
cat /etc/network/interfaces                 # find the bridge over the balteus bond (vmbr0, most likely)
cp /etc/network/interfaces /root/interfaces.bak-$(date +%F)
# in that bridge's stanza add:
#     bridge-vlan-aware yes
#     bridge-vids 1-4094
ifreload -a
```

**Expect a short interruption on that bridge** while it is re-made — this is a normal consequence of
turning a bridge VLAN-aware, not a failure. The out-of-band path is the IPMI at `172.16.10.46`, which is in
management and unaffected; if `ifreload` ever does not come back, that is the way to fix it.

Verify: `ip -d link show vmbr0 | grep -i vlan` shows the bridge as VLAN-filtering, the host still answers on
its compat address (`172.16.100.38`), and `bridge vlan show` lists VLAN 1 (and the class vids you enabled).

## Step 2 — move one guest at a time

Start with something disposable, and change **two** things per guest: the NIC's tag, and the guest's own
addressing (DHCP from the class scope, or a static with that class's gateway).

```bash
qm config <id> | grep net0                   # note the current line, you will want it for the rollback
qm set <id> --net0 <bus>,bridge=vmbr0,tag=40  # a srv guest: 10 mgmt / 30 lab / 40 srv / 60 vpn / 70 iot
```

Then, from inside the guest: it should take an address from the class scope (`dhcp-srv`, `dhcp-lab`, … —
each hands out its own gateway and `8.8.8.8`), reach its class gateway (`.10.1` / `.30.1` / `.40.1` /
`.70.1` / `.96.1`) and the internet. If a guest needs another class, that is a firewall question now, not a
tag question — `iot` reaches nothing internal, `lab` reaches nothing in mgmt, and so on.

Authoring note: `dhcp.tf` is where fixed identities are declared, so a guest that must keep its address
suffix across classes gets a reservation there, in the same PR that moves it — the pattern the Sparks and
the probe already follow.

## About `bond1` — measured, and the answer is "leave it"

`bond1` has exactly **one** slave (`eno1`), and the switch's side has exactly **one live member**: `ether2`
(`13.7 GB` transmitted; `ether1` is dark, `rx=0 tx=0`). So there is nothing to dissolve "for `eno2`" — `eno2`
was never in the bond; it is a separate device on its own bridge. A single-member LACP bond gives no
aggregation and costs nothing; the switch negotiates LACP on the one live link and carries on.

If you want it tidied anyway, both sides must change **in the same window** or the LAN link dies in between:
the host drops to bare `eno1` (no LACP) and the switch's bond is replaced by a plain `ether2`. That is a
switch change this repo owns, so it would be a PR merged *in* that window — and the lifeboat from Step 0 is
what makes the window safe, since `bond0` and the fabric are untouched by it. Not worth doing for its own
sake.

Worth considering later instead: the switch's `ether1` is dark, and `enp68s0` on the host is unused
(`autostart=No`). If it is a usable port on that card, it would make a real two-member LAN bond — the
guests' estate-facing traffic (the vault's NFS at `172.16.100.148` included) runs over one link today.

## The vault has two addresses, and both matter

`truenas` (`vm 101`) answers at `172.16.100.148` (compat, estate-facing — the NFS the Hermes host mounts)
**and** at `192.168.0.250` on the storage fabric (spark-facing). Moving it to `srv` has to keep both paths
working, which is the second reason it goes last: its NICs sit on two different bridges with two different
jobs.

## Suggested order

1. a **stopped, disposable** guest (`sandbox`, `agentic-sandbox`) — proves the path end to end with nothing
   at stake;
2. the **running sandboxes and CI** (`kubernetes-sandbox`, `github-dind`) — lab, low blast radius;
3. the **cluster nodes** (`main-*`, `kubernetes-master`, `cpu-worker0`) — decide lab or srv per node before
   tagging, since the class decides what they may reach;
4. the **keepers** (gitlab, authentik/proxy, coder, portainer, …) — srv;
5. **`truenas` last.** It is the vault: moving it drops NFS for the Hermes host and everything else until it
   is back, so it should be done in a window, with the host's other guests already settled.

## Rollback

Per guest: `qm set <id> --net0 <the original line>` and fix its addressing back to compat
(`172.16.100.x`, gateway `172.16.100.1`). That is the whole rollback — the switch side needs nothing,
because compat was never disturbed.

Whole-host: remove the two `bridge-vlan-*` lines and `ifreload -a` (same short interruption).

## Open question, recorded rather than resolved

`172.16.30.189` — the `inference VM` reservation in `dhcp.tf` — holds a **lab lease** (`BC:24:11:5D:F4:C7`)
while the switch's VLAN table says a tag from the balteus bond cannot be carried yet, and the router has no
fresh ARP for it in `vlan30-lab`. So its lease is most likely a leftover from an earlier arrangement. Worth
five minutes before the guests start moving, because it is the one guest whose class is already claimed.
