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
the router's own resolver (`allow-remote-requests`) is off, so DNS in the matrix means *public*
resolvers until the resolver step, and enabling it is what lets internal names work for VPN clients
— the same decision as pointing `lmproxy` at names.

## What this deliberately leaves alone

- **IPv6** — out of scope for the overhaul; the classes are IPv4, and nothing in the matrix assumes
  a second family.
- **The VPN's own addressing** — the tunnel transport block is separate from the zone segment, and
  both belong to the `vpn` row.
- **Per-device exceptions** — every one of them is a rule with a comment and a class reason, and
  they are reviewed like code. A matrix that grows exceptions silently is just the flat LAN with
  more steps.
