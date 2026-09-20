# The stories exception — one destination, two identities, every other device denied.
#
# WHY THIS FILE EXISTS
# ----------------
# `stories.red-ink.hnatekmar.dev` is served by `stories-hermes`, one VM in `srv` at `172.16.40.188`.
# Measured 2026-09-20, and all three facts decide the shape of what follows:
#
#   * the name is a plain A record in the **public** zone pointing at that internal address
#     (`red-ink.hnatekmar.dev` and `*.red-ink.hnatekmar.dev` → `172.16.40.188`, `proxied=false`), so DNS
#     answers it everywhere and the answer is meaningless outside the estate;
#   * the NAT table carries **no `dstnat` rule for `.40.188`** — the box is not published to the WAN, and
#     the five `dst-address-list=wan` accepts at the top of the forward chain govern the *edge* host, not
#     this one. It is reachable from inside the estate and from nowhere else;
#   * so "who may read the stories" is a LAN question, and this file is its answer.
#
# Martin's policy, 2026-09-20 — the **destination** is the unit of policy here, not the source class:
#
#   * charon (the work PC, `172.16.10.200`, mgmt)  → **full access**, every port
#   * the reader tablet (iot)                      → **TCP 443 only**
#   * every other device on the estate             → **nothing**
#
# WHY A DESTINATION-SCOPED BLOCK AND NOT A CLASS ROW
# ----------------
# The matrix's rows are class-to-class (`docs/firewall-matrix.md`), and a row is the wrong instrument for
# this: mgmt → srv is ✓, srv → srv is ✓ (its own segment), and `lab → srv` is still log-only — so *today*
# four of the six classes can reach this box, and none of those rows is the thing being changed. What is
# being changed is one host's reachability, so it is written as one host's policy: a destination list
# (`stories-host`, one address, from its reservation in `dhcp.tf`) with two accepts and a deny. Nothing
# class-level moves, and nothing else in `srv` is affected — the deny matches on destination only.
#
# The identity side follows the estate's own rule for a one-device exception (the reader's): key it on an
# address **claimed by a DHCP reservation**, never on a MAC. `172.16.10.200` was a *dynamic* `dhcp-mgmt`
# lease until this change — the address the exception is written against had no owner, so the pool could
# have handed it to a different device and that device would have inherited full access. The reservation
# in `dhcp.tf` (measured MAC `E2:01:50:75:5F:39`) is what makes it charon's.
#
# ORDERING (measured on the device 2026-09-20 — not assumed)
# ----------------
# Forward chain as it actually is: `dstnat` accepts at 2–6 (`dst-address-list=wan` + nat-state dstnat, so
# they are about inbound-published traffic and irrelevant to every rule here); a hand-made MAC drop at 12;
# fasttrack at 17; `accept established,related,untracked` at 18; the class drops and the reader's accepts
# interleaved at 21–30; `reader_no_wan` appended at 41; no terminal accept, so unmatched traffic falls
# through and is *accepted* — which is exactly what these denies have to pre-empt.
#
# Therefore, and each line is load-bearing:
#
#   * every rule here must sit **below position 18**. Above the connection-tracking accept, a deny would
#     begin judging reply packets — and for a destination-scoped deny that failure is subtler than usual:
#     replies from the box are `src=stories`, which this rule does not match, so the break would come from
#     the *other* direction. `scripts/matrix-order-check.py` asserts the invariant chain-wide anyway, and
#     these rules keep it by construction.
#   * `stories_host_deny` is anchored **above `reader_web_allow["SRV"]`**, not appended like every other
#     matrix drop. That is the whole difference between "the tablet may reach stories on 443" and "the
#     tablet may reach stories on 80 and 443": the reader's general web accept covers port 80 as well, and
#     an appended deny sits below it and never sees the traffic. The anchor therefore *is* the policy —
#     this destination out-ranks the reader's blanket-web-ports accept, and the file says so out loud
#     because the next person to read `reader-lan-only.tf` will otherwise expect its rule to win.
#   * the two accepts anchor on the deny (`place_before = …stories_host_deny.id`), so they are inserted
#     ahead of it in the same apply. Same pattern as `iot_router_dhcp` — a brand-new rule anchoring on a
#     brand-new rule is free; anchoring on a *live* rule would force its replacement, which is why the
#     anchor above names the reader's rule rather than re-anchoring it.
#
# WHAT THIS COSTS, STATED PLAINLY (the log is the receipt)
# ----------------
# A deny is only as honest as its blast radius, so: **every** other identity on the estate loses this
# host, including things that work today by falling through the chain.
#
#   * `personal-hermes` (`.10.180`, mgmt, the operator host — this agent's own box): measured reaching
#     `https://stories.red-ink.hnatekmar.dev/` → 200 before this change; denied after it. If automation
#     there should keep reading stories, that is one more accept, and a decision rather than an omission.
#   * **vpn clients**: `vpn → srv` is ✓ in the matrix on service ports, so a tunnel client reaches this
#     box today and will not after this change. Note also that charon *itself* is only excepted at its
#     mgmt address — reading stories from charon over the tunnel is a different source address and is
#     denied with the rest.
#   * `srv` peers (including the edge host, sister-hermes, the clusters) and `compat` — compat's row is
#     "everything" until it drains, so this is the first destination compat does *not* get.
#   * the iot class's verdict for this one host moves from `MTX-IOT>SRV` to `MTX-STORIES>DENY`: the class
#     drop still covers the rest of `srv`, but an attempt on this address is now counted under this
#     prefix. Any report that maps `MTX-<CLASS>><CLASS>` rows to a matrix cell needs a row for the new
#     prefix; the estate's report script is not in this repo yet (`scripts/matrix-deny-report.py` is
#     referenced by `stage3-firewall.tf` but absent here), so that is a note for whoever lands it.
#
# The deny is `log=true` with its own prefix for exactly this reason: the first week of counters is the
# evidence of what was actually lost, read the way `stage 3, phase 1` taught — measured, not asserted.
#
# END STATE
# ----------------
# This is a per-destination policy for one service, and a second such service makes it a table rather
# than a file (one list and three rules per destination). The honest move then is a `published services`
# section in the matrix with its own shape — not a fourth copy of this block.

locals {
  # charon — the work PC, on the CSS610's mgmt access port. One device, stated once: `main.tf` takes the
  # address for `charon-nets` from here, and `dhcp.tf` claims the same address with the same MAC, so a
  # second literal cannot drift from these rules.
  charon = {
    address = "172.16.10.200"
    mac     = "E2:01:50:75:5F:39"
  }
}

# Full access: every port, no protocol restriction — the destination list is the narrowing criterion.
# (The guardian in `matrix-order-check.py` forbids an accept with *no* narrowing criterion; a src+dst
# pair is a criterion, so this rule is not the blanket accept that assertion is looking for.)
resource "routeros_ip_firewall_filter" "stories_allow_charon" {
  chain            = "forward"
  place_before     = routeros_ip_firewall_filter.stories_host_deny.id
  action           = "accept"
  src_address_list = "charon-nets"
  dst_address_list = "stories-host"
  comment          = "stories: charon (the work PC) has full access — firewall-matrix.md"
}

# The tablet, on one port. 443 alone and not `80,443`: the browser will reach it as `https://…`, and the
# port-80 redirect a bare hostname would need is deliberately not granted — adding it back is this one
# string, and it is a decision rather than an oversight.
resource "routeros_ip_firewall_filter" "stories_allow_reader" {
  chain            = "forward"
  place_before     = routeros_ip_firewall_filter.stories_host_deny.id
  action           = "accept"
  src_address_list = "reader-nets"
  dst_address_list = "stories-host"
  protocol         = "tcp"
  dst_port         = "443"
  comment          = "stories: the reader tablet, on 443 only — firewall-matrix.md"
}

# Everyone else, in one rule: no source list, because the policy is about where the traffic is going.
# Anchored above the reader's general web accept — see the ordering note above; that anchor is the
# difference between 443-only and 80,443 for the tablet.
resource "routeros_ip_firewall_filter" "stories_host_deny" {
  chain            = "forward"
  place_before     = routeros_ip_firewall_filter.reader_web_allow["SRV"].id
  action           = "drop"
  log              = true
  dst_address_list = "stories-host"
  log_prefix       = "MTX-STORIES>DENY "
  comment          = "stories: nobody but charon and the reader tablet reaches this host — firewall-matrix.md"
}
