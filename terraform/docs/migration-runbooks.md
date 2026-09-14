# Migration runbooks — the steps after the router's filtering change

Step 1 (the RB5009 becoming VLAN-aware) is applied and verified: `vlan-filtering=yes`, `ether1` an
access port in the mgmt VLAN, both bridge VLAN entries, the class VLANs in the LAN list, **8/8
bridge ports still hardware-offloaded**, compat untouched, and the `ether1` probe reaching the
router's management port from inside mgmt.

These are the steps that follow. Each is its own PR and its own window, and each keeps the same
two properties as step 1: **zero behaviour change for everything not named**, and an **escape port
already proven** before anything moves.

House rules for every window, from the two mistakes that cost real debugging time today:

- **Fetch before you branch.** A tree one merge behind plans *destroys* for objects a later PR
  added. If a plan offers to delete bridge VLAN entries, suspect your tree before the device.
- **Adopt before you change.** A new resource argued into existence by a plan is safer than one
  argued into existence by a paragraph. Import first, plan zero, then change one attribute.
- **A device-reported field is not necessarily writable** (`vrf` is reported and rejected).

---

## 1. CRS326 — the same treatment as the router

Escape port `ether3`, then filtering with everything still compat. No routing on this device, so
the risk profile is simpler than the router's, but two things need deciding first:

| Question | Why it matters | Recommendation |
|---|---|---|
| Does the switch need an address in the mgmt VLAN? | On the router, `ether1` gives access to the *router's* mgmt address. Here, `ether3` alone reaches nothing — the CRS326's only address is `172.16.100.2` in compat | **Yes**: give it `172.16.10.2/20` so `ether3` stands alone and the escape doesn't depend on the router's mgmt path |
| Its management address moves when? | The switch is managed from compat today | Leave `172.16.100.2` in place, add the mgmt address alongside, retire the old one with compat |

Acceptance test: every port still `hw=yes` (24/24 today), the compat LAN unaffected, and a laptop on
`ether3` reaching `172.16.10.2` **and** opening WinBox on it.

## 2. CSS610 — the one that must be done by hand

No API, no scripting, and it sits on the path to charon, to all four Sparks' management and to the
spine's management. Its ports are hand-labelled, which is the only reason this is tractable.

| Port | Name on the switch | Setting | Class |
|---|---|---|---|
| Port7 | `CRS326 Port 4` | **trunk**: tagged 10, 30; untagged 1 (compat) while it drains | — |
| Port2 | `Charon` | access, pvid 10, untagged-only | mgmt |
| Port4 | `CRS04-4DDQ ETH1` | access, pvid 10, untagged-only | mgmt |
| Port3, 5, 6, 8 | `Spark 4/3/2/1` | access, pvid 30, untagged-only | lab |
| Port1 | — | spare **— pre-assign as the escape port (pvid 10)** | mgmt |

Write the recovery step down before touching anything: **a laptop with `172.16.10.50/20`, gateway
`172.16.10.1`, on Port1** — and keep it in your hand, because the switch has no remote fallback.

Order: Port1 first (make the escape real), then Port2/Port4 (charon and the spine's management),
then the four Spark ports, then the trunk on Port7 **last** — the trunk is the only edit that can
take the other ports down with it.

**This is the step that moves Hermes' inference endpoint `172.16.100.136` — see the appendix.**

## 3. CRS804 — one address, last of the switches

Its VLAN footprint is a single management address on a single-member bridge (`bridge1`, `ether1`).
`bridge-compute` — the storage and RDMA fabric, four QSFP ports plus the NAS link — is **never
touched**, and its two software-bridged ports are pre-existing, not drift.

**Gated:** do this only once charon is already in the mgmt VLAN. `ether1` is the only way into the
box, so a mistake here cannot be fixed remotely from compat — the fix is a physical trip.

## 4. balteus — the largest single change

PVE's bridge becomes VLAN-aware and each guest NIC carries its class tag. 46 guests, one at a time.

```
# /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

Then per guest NIC: `tag=<vid>` — `10` mgmt, `30` lab, `40` srv, `60` vpn, `70` iot.

| Item | Detail |
|---|---|
| balteus' own management | `srv` — it is a keeper |
| its storage NIC | stays on the storage island, untouched |
| `vmbr3` (host-internal fast path) | untouched — no physical member |
| Migration order | **Hermes first** (see the appendix), then the inference VM, then the rest class by class |
| Rollback | remove the tag, `bridge-vlan-aware no`; the compat VLAN entry keeps untagged guests working throughout |

Two consequences worth knowing before, not after: same-host same-class pairs keep switching inside
balteus, while **cross-class pairs traverse the router** (policy lives there, and so does the CPU
cost); and the bond carrying all of it is 1 Gb on a single live member — the storage and fabric
paths ride separately, so it is not a capacity problem, but it is why the bond keeps coming up.

## 5. Retiring compat

When the last device has moved: the three resources in `stage2-filtering.tf` (the `vlan1-compat`
deferral note, the address adoption, the VLAN 1 bridge entry) come out, trunks go tagged-only with
`pvid 999`, and the compat DHCP scope and address lists go with them. One PR, reviewed like the
others, verified by a plan that shows exactly those deletions and nothing else.

---

## Appendix — keeping Hermes available through all of it

The agent runs on `172.16.100.180` and reaches the inference fleet **by IP**, through
`lmproxy.service`:

| Endpoint in lmproxy | Host | Moves at | Becomes |
|---|---|---|---|
| `http://172.16.100.136:8000` | spark1 | CSS610 hand config | `http://172.16.30.136:8000` |
| `http://172.16.100.189:8030` | the inference VM | balteus trunk | `http://172.16.30.189:8030` |

**The addresses are stable by construction, not by luck.** The class DHCP scopes avoid `.100–.199`
and declare static leases for these five hosts at their current suffixes, so each move changes the
*subnet* and nothing else — a two-line edit, prepared in advance, not a discovery.

Three things to do at each window:

1. **Immediately before:** confirm the endpoint answers (`nc -z <ip> <port>`), so a later silence
   has a known baseline.
2. **At the moment the port moves:** apply the prepared edit and `systemctl restart lmproxy`
   (~1 s), then confirm the new endpoint answers. Expect a short inference gap while the device's
   port re-negotiates — the proxy is not the bottleneck, the move is.
3. **Immediately after:** `curl` one model through the proxy, not just the TCP port — a listening
   socket is not a working model.

**And the structural fix, during the balteus step:** give this host a **mgmt-VLAN** presence
(`172.16.10.180`). Today the agent lives in compat, so any step that disturbs compat takes the
agent with it — including the step that moves it. In mgmt it reaches the classes by design
(`mgmt → everything`), matches the class it actually is (admin-plane infrastructure, holding the
keys to the estate), and stops being a hostage of the segment under change.

Longer term, once the router serves DNS (the deliberate resolver step), point `lmproxy` at
**names** (`spark1.dev.hnatekmar.xyz` and friends) and re-addressing stops touching it at all.
That is the same decision as the split-horizon resolver the VPN needs, so it is one piece of work,
not two.
