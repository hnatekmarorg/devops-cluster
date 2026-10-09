# The firewall matrix — stage 3, in design form

The classes exist and the router is VLAN-aware. What does *not* exist yet is any policy between
them: today every class VLAN is in the LAN interface list, so the truth about the estate is
"everything inside can reach everything inside", which is exactly what the carve is meant to end.

This document is the policy **as a reviewable table**, before it becomes firewall rules. It is
deliberately written to be argued with — a matrix is a claim about what the estate is for, and it
is cheaper to disagree with a table than with a working config.

## Intent per class

| Class | What it is | Trust | Egress | Its reach is a *consequence* of |
|---|---|---|---|---|
| mgmt | the admin plane: what you administer **from**, plus out-of-band (IPMIs, switch/router management, the Hermes host) | highest | internet | being the plane that must be able to fix everything else |
| srv | the keepers: the services everything depends on (NAS, git, identity, registry, balteus) | high | internet | being depended upon, not its own privilege |
| lab | workloads: code that runs other people's code, the AI compute, sandboxes | low | internet, **restricted** | needing to work without needing to be trusted |
| iot | untrusted devices, including the entire WiFi segment | lowest | internet | nothing — internal reach is the VPN's job |
| vpn | WireGuard clients | medium | internet + scoped internal | an authenticated identity, not a location |
| compat | the legacy flat segment, draining | transitional | everything | existing until it is empty |

## The matrix

`→` means "may initiate". Blank means deny. Ports are named where the class boundary is a service
boundary rather than an all-or-nothing one.

| From ↓ / To → | mgmt | srv | lab | iot | vpn | internet |
|---|---|---|---|---|---|---|
| **mgmt** | ✓ | ✓ | ✓ (+ monitoring scrape) | ✓ | ✓ | ✓ |
| **srv** | responses only | ✓ | responses (it serves lab) | ✗ | responses | ✓ |
| **lab** | **✗** | ✓ on service ports: git, identity, DNS, NTP, registry/model cache | ✓ | ✗ | ✗ | restricted, log-only first |
| **iot** | ✗ | ✗ | ✗ | ✓ (its own segment) | ✗ | ✓ only |
| **vpn** | ✓ scoped | ✓ on service ports | ✓ scoped | ✗ | ✓ | ✓ |
| **compat** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ *(transitional — deleted with compat)* |

Three deliberate asymmetries, each of which someone will otherwise "fix":

- **lab → mgmt is denied, and that is the point.** A box that runs other people's code does not get
  the plane that holds the router, the switches and every IPMI. Where admin access is genuinely
  needed, the *device* moves to mgmt or a named `mgmt → lab:22` rule is added and reviewed — never
  the whole class.
- **srv initiates almost nothing.** It serves; consumers initiate. A keeper that could reach the
  admin plane would be a second admin plane with extra steps.
- **compat keeps everything until it dies.** It is the migration's load-bearing assumption: any
  device not yet moved must keep working as it does today. The row is deleted in the same PR that
  retires the segment — not left to rot.

## Rollout — measure, then enforce

Tightening a live estate on the strength of a table is how outages get scheduled. The sequence:

1. **Log what the matrix would deny.** For each intended deny, add an `action=log` rule with a
   distinctive `log-prefix` and leave the traffic flowing — RouterOS logs and continues, so the
   rule is a counter, not a verdict. Read the logs for a week.
2. **Enforce the confident rows first**: `iot → internal` (nothing should be there), `lab → mgmt`.
3. **Then the service-boundary rows**, port by port, where the logs showed real traffic.
4. **Retire compat** and delete its row.

### Class lists must be disjoint

A class row is written against an address *list*, and two lists that overlap make a packet match two rules —
at which point first-match-wins decides the class, not policy. That is not hypothetical: the enforced
`lab → vpn` drop swallowed every `lab → compat` flow on 2026-09-15, because **compat `172.16.100.0/24`
sits inside the vpn block `172.16.96.0/20`**. The plan puts compat "outside the blocks", which is true of the
*host spaces* and false of the *policy blocks*. `vpn-nets` therefore enumerates the /20 minus `100.0/24`,
so each address has exactly one class and rule order cannot change a verdict.

### The invariant has a guardian

RouterOS has no rule priority — order *is* the priority, first match wins — and the provider models no
position, so **placement is invisible to `plan`**: a bare `accept` inserted above the matrix changes the
policy with no diff anywhere. `scripts/matrix-order-check.py` therefore asserts the three things the rules
depend on, against the live router, read-only:

1. each matrix rule (`log-prefix` starting `MTX-`) exists **at most once** — a recycled `.id` can make the
   provider re-create a rule, and a duplicate is a silent second judgement;
2. every matrix rule sits **below** its chain's connection-tracking accept — above it, a deny breaks reply
   packets, whose tuple (src iot, dst internal) matches the deny itself;
3. no **blanket accept** sits in the chain at all: an accept without any narrowing criterion
   (connection-state / nat-state / ipsec / address / port / protocol) is exactly the shadow the invariant
   forbids.

Exit 0 holds, 1 violated, 2 could not measure.
The endgame is *adopted* state: once the router's whole chain — and its NAT — is declared in Terraform,
placement becomes reviewable rather than asserted, and this check retires into a smoke test. Until then
it is the only thing standing between the table above and a rule nobody meant to add. It belongs in the plan workflow (the job already has read
credentials) and in whatever cadence reads the deny logs — the two together are the measure-then-enforce
loop: this one says the policy *can* work, the report says what it would cost.

The existing *defconf* rules stay: they govern the WAN side (`drop all from WAN not DSTNATed`, the
input chain's WAN handling) and the matrix is about east-west. Two interactions to keep in mind:
the router's own resolver (`allow-remote-requests`) is **on** as of `dns.tf` (measured on the device
2026-09-19 — this document said "off" until then, and the change is what lets internal names work for
VPN clients, for the reader below, and is the same decision as pointing `lmproxy` at names). The
matrix therefore no longer means *public* resolvers for classes that are allowed to ask the router.

## The reader exception (2026-09-19)

One device — a tablet used as an e-reader and to browse internal services — gets the **inverse of its
class row**: internet denied, internal web allowed. It lives in iot (`172.16.70.25`), whose row is
"internet ✓ only", so this is a per-device exception in the sense of the last section: a rule with a
comment and a class reason, reviewed like code (`terraform/routeros/reader-lan-only.tf`).

**The class reason.** The device's purpose is to hold the vendor's telemetry *inside* the house and
still be useful, which is the opposite of both available class rows. iot's row lets it phone home and
gives it nothing internal to reach; the LAN classes would give it everything internal *and* the
internet. Neither is the intent, so the intent is written down: **no internet, and only web ports to
internal destinations.**

**Both halves are one change.** A WAN deny alone would leave the device able to reach nothing at all,
because `iot → internal` is already denied. Conversely, the LAN accepts are *narrow*: `src=reader-nets`,
`dst=<class>`, `tcp 80,443`. No blanket accept, so the guardian's third assertion still holds.

**One destination is not a web port.** The reader also reads a share on the NAS, and SMB is `tcp 445` —
outside the accepts above, so it gets its own rule: `reader_smb_allow`, one host wide (`nas-smb`, the
NAS's `srv` address) and one port wide, anchored above `MTX-IOT>SRV` the way the web accepts are anchored
above theirs. The shape that would need no rule at all is worth naming, because it is the tempting one:
the NAS has a second NIC inside `iot`, and the matrix lets a class reach **its own segment** (`iot → iot
✓`). That path makes the reader's reach a property of whatever the NAS binds on that interface, and hands
the same reach to every untrusted device on the segment — so the reader's SMB goes to the `srv` address
and this rule is the one that says "samba, one host, and nothing else".

**Two policies are deliberately contradicted, each with one reason.** iot keeps public DNS and public
pool time *because it has internet* (see `iot_router_deny`). Once the internet is denied, neither
exists for this device: a resolver and a clock have to come from somewhere, and the router is the only
something. Without NTP the clock drifts and TLS fails — a functional requirement, not a nicety.

**A firewall accept alone does not deliver DNS.** The iot scope hands out `dns-server=8.8.8.8` (read off
the device), so allowing DNS *to the router* changes nothing unless the device is told to ask it: hence
a per-lease DHCP option set (option 6 → the estate's resolver) on this one reservation, while the
class's own "public DNS" policy stays untouched. Three device constraints, every one of them learned by
failing an apply rather than by `validate`: `dst-port` is illegal without a protocol; the `protocol`
field takes **one** name or number, never a list, so covering udp *and* tcp needs **two rules** (and
both are needed — a filtered resolver truncates to TCP); and the option's value must be **typed**
(`s'…'`) or the device answers "Unknown data type!".

**The clock is an open gap, not a solved one.** iot sets `ntp-none=true`, so nothing is advertised and
this accept permits traffic that is not yet invited; it is written so that advertising the router as
time source (option 42) becomes a DHCP-side change only. Measured 2026-09-19: `ntp.tf` declares the NTP
server `enabled = true` while the device reports `enabled=false` — that drift is the real blocker and it
belongs to the NTP work. Until then a reader with no internet has no time source, and a drifted clock
breaks TLS against internal services.

**Ordering is derived from the device, not assumed.** Measured: the five `dst-address-list=wan` accepts
match `connection-nat-state=dstnat` (inbound-published), so they are irrelevant to egress; the class
drops sit at 21–26; there is no terminal accept, so unmatched traffic falls through and is accepted —
which is how iot keeps its internet today, and what an appended deny pre-empts. Hence the deny is
appended (the convention for matrix drops) while the accepts carry `place_before` anchors on the class
drop they contradict; an appended accept would sit *below* it and never match.

**Fail-open, stated — narrower than it was, not gone.** The identity is still one address claimed by a
reservation keyed on one MAC, but that MAC is now the device's own (locally-administered bit clear), so
this no longer rides on the SSID's private-MAC setting. The residual: a factory reset or a
forget-and-rejoin returns Android to a randomized MAC by default, the reservation then matches nothing,
the list matches nothing, and the device quietly reverts to the iot row — internet back, LAN gone. Not
hypothetical: measured 2026-09-20, that is the state this exception was *found* in — reservation
`waiting`/`last-seen=never`, address list still on the old number, zero packets on all seven reader
rules, device in use. The check is therefore the byte counter on the WAN deny: a device in use with zero
packets is no longer matching.

The address (`.25`) sits *inside* the iot pool, deliberately: it is where the device's dynamic lease had
already settled, so claiming it re-addresses nothing — and a static lease keeps its address busy, i.e.
out of dynamic assignment, for as long as the reservation exists.

**End state.** A second reader device makes this file the wrong answer. The honest move then is a
`reader` class — own VLAN, own SSID, own DHCP scope, its own row above — and this exception is deleted
with the file it lives in.


## The stories exception (2026-09-20)

`stories.red-ink.hnatekmar.dev` is served by `stories-hermes`, one VM in `srv` at `172.16.40.188`. Three
measurements decide its shape — the name is a plain A record in the **public** zone pointing at that
internal address (`proxied=false`), so DNS answers it everywhere and the answer means nothing outside the
estate; the NAT table has **no `dstnat` rule for `.40.188`**, so the box is not published; and therefore
who may read it is a LAN question. The policy is destination-scoped, and it lives in
`terraform/routeros/stories-access.tf`:

| Identity | Reach |
|---|---|
| **charon** (the work PC, `172.16.10.200`, mgmt) | **full** — every port |
| **the reader tablet** (iot, `172.16.70.25`) | **TCP 443 only** |
| every other device on the estate | **nothing** |

**Why not a class row.** This is the first policy here whose unit is *one destination* rather than a
class pair, and the class table cannot express it: mgmt → srv is ✓, srv → srv is ✓, `lab → srv` is still
log-only, and compat's row is "everything" until it drains — so four of the six classes reach this box
today, and none of those rows is what is being changed. The rules are therefore a **host** destination
list (`stories-host`, taken from `stories-hermes`'s reservation) with two accepts and one deny, and
nothing class-level moves.

**The anchor is the policy.** `stories_host_deny` is placed *above* the reader's general web accept
(`reader_web_allow["SRV"]`) rather than appended like every other matrix drop. Without that, the tablet
keeps `80,443` to this host through the reader's own rule, and the "443 only" line above would be a
description the diff does not support. The cost is stated rather than hidden: a bare-hostname request
from the tablet, which would need the port-80 redirect, is refused; `80,443` is one string away if that
turns out to matter. The two accepts anchor on the deny, so all three land in one apply in the right
order — the `iot_router_dhcp` pattern.

**The identity was the harder half.** A one-device exception is keyed on an address, and the address has
to be owned: `.10.200` was a **dynamic** `dhcp-mgmt` pool lease (measured), so the exception as first
imagined would have followed whatever device the pool handed that number to. `dhcp.tf` now claims it for
charon's measured MAC, which is also why `charon.mgmt.hnatekmar.dev` follows its reservation instead of
carrying a literal. The MAC is randomized (locally-administered bit set — Windows' random hardware
addresses), so the failure mode is a rotation that unmatches the reservation: charon then takes a
different pool address and loses the exception, the **closed** direction, with no other device gaining
it. The durable fix is on the adapter's setting.

**What it costs, and how we will know.** The deny is `log=true` under `MTX-STORIES>DENY `, so the first
week of counters is the receipt for everything that was reaching this host by falling through the chain
— measurably: `personal-hermes` (`.10.180`, mgmt — the operator host) answered `200` before this change
and loses it after; **vpn clients** lose it too, including charon over the tunnel, since the exception is
its mgmt address and not the identity behind it; `srv` peers and compat lose it as well. Two follow-ups
belong to whoever reads that log: a report that maps `MTX-<CLASS>><CLASS>` rows to a matrix cell needs a
row for this prefix, and `iot → <this host>` now counts under it instead of `MTX-IOT>SRV` (the class drop
still covers the rest of `srv`).

**End state.** A second such service makes this a table (one list, three rules per destination) and the
honest move then is a *published services* section with its own shape — not a fourth copy of this block.


## The tunnel endpoint (2026-09-25)

The `vpn` class stops being hypothetical with WireGuard on the router
(`terraform/routeros/wireguard.tf`), and publishing the endpoint is a *policy* change rather than one
firewall port. Three of its properties are invisible to `plan`, and each is a way for a correct-looking
config to do nothing at all.

**It is the estate's first WAN input accept.** Everything addressed to the router that did not arrive on
a class VLAN meets the defconf `drop all not coming from LAN` (`in-interface-list=!LAN`) — which is why
the box has never had a WAN-facing service, and why "expose one port on the router" reads as far more
work than it is. The accept has to sit **above that rule**; no Terraform-managed rule sits above it, so
its id is read at plan time through the provider's generic `routeros_ip_firewall` data source rather than
being appended below (where it would never match).

**The class that most needs the tunnel is the one that cannot reach it by default.** A client at home sits
in `iot`, whose row is "internet ✓ only" and whose router access is a default-deny (`iot_router_deny`) —
so `iot` gets a narrow accept for the tunnel port, anchored above that drop, in exactly the shape the DHCP
accept beside it already has. Without it, the device that needs the tunnel most is the one that cannot
bring it up and its client config looks correct while doing nothing. It is a *class* accept rather than a
destination-scoped one on purpose: the input chain already means "addressed to the router", and `iot` is
handed a **public** resolver, so this client resolves the endpoint to the WAN address and the packet
arrives over the bridge addressed to the router's own WAN address. There is no `dstnat` in that path, so
no NAT hairpin is involved.

**The tunnel's own traffic to the router is scoped to one service: DNS.** The WireGuard interface is
deliberately *not* added to the `LAN` interface list — that membership is the crutch the class
default-denies exist to replace — so decapsulated traffic to the router's own addresses meets the same
defconf drop and is denied except where named. A tunnel client's resolver is the router's address in its
class (`172.16.96.1`, the `vlan60-vpn` gateway), which is the rule every DHCP scope already follows, and
it needs **udp and tcp as two rules** (a filtered resolver truncates to TCP). NTP is not added: a client
that is not the internet-less reader takes time from whatever network it is on.

**What the tunnel may reach is not enforced yet, and that is a decision with a consequence.** There is no
catch-all in the forward chain, so a class row's ✓ cells are satisfied by *fall-through*: the `vpn` row
(mgmt scoped · srv on service ports · lab scoped · iot ✗) describes the intent, while a tunnel client
today falls through to everything internal. Q21's enforcement order is iot → lab → srv → mgmt with compat
last, and `vpn` is not in it — so the accept-list that enforces this row is its own reviewed step, and it
needs the service-port list the `lab → srv` measurement is producing. Stated here rather than left
implied, because it is the one thing about the tunnel a reader could reasonably assume the opposite of.

Against that: the router's **own** input chain *is* scoped by this change — the tunnel reaches the
endpoint and the box's resolver, and nothing else on the device.

## What this deliberately leaves alone

- **IPv6** — out of scope for the overhaul; the classes are IPv4, and nothing in the matrix assumes
  a second family.
- **The VPN's own addressing** — the tunnel transport block is separate from the zone segment, and
  both belong to the `vpn` row.
- **Per-device exceptions** — every one of them is a rule with a comment and a class reason, and
  they are reviewed like code. A matrix that grows exceptions silently is just the flat LAN with
  more steps.
