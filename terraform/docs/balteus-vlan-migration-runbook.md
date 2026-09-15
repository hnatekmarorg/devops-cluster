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
