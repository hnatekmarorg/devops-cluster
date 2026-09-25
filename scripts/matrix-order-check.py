#!/usr/bin/env python3
"""Assert the firewall matrix's placement invariant on the live router.

Why this exists: RouterOS has no rule priority — *order* is the priority, first match wins — and the
providers only let you state intent at write time. The terraform-routeros provider has no attribute that
models where a rule *sits*, so a plan cannot see it: someone adding a bare `accept` above the matrix
rules would change the effective policy with **no diff anywhere**. That is the failure this script is
for.

The invariant, as written in `terraform/routeros/stage3-firewall.tf`:

  1. every matrix rule (`log_prefix` starting `MTX-`) exists **at most once** — a recycled RouterOS
     `.id` can make the provider re-create a rule, and a duplicate is a silent second judgement;
  2. every matrix rule sits **below** the connection-tracking accept of its chain — above it, a deny
     would break reply packets, whose tuple (src iot, dst internal) matches the deny itself;
  3. nothing **above** a matrix rule accepts traffic the matrix is meant to judge: an `accept` that is
     not narrowed (no connection-state / nat-state / ipsec / address / port / protocol) shadows the
     class policy. Checked chain-wide, because matrix rules are appended last.
  4. every WireGuard accept sits **above** the drop it has to precede (`terraform/routeros/wireguard.tf`).
     Those rules are inserted by rule *id* at write time — because the defconf drop they precede is the
     device's own and not in this configuration — so their position is invisible to `plan` in exactly the
     same way the matrix's is, and one of them is the estate's first WAN input accept.

Read-only. Exit 0 = invariant holds, 1 = violated, 2 = could not measure. Credentials are never printed.

Usage:
  matrix-order-check.py            # assert + print the chain it measured
  matrix-order-check.py --quiet     # only speak when something is wrong (for cron/CI)
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

CREDS_FILES = [
    "/root/network-migration/credentials/routeros.env",
    str(Path.home() / ".hermes" / "credentials" / "routeros.env"),
]
ROUTER_HOST = os.environ.get("MATRIX_ROUTER_HOST", "172.16.100.1")
ROUTER_PORT = int(os.environ.get("MATRIX_ROUTER_PORT", "8728"))
MATRIX_PREFIX = "MTX-"

# The WireGuard accepts (`terraform/routeros/wireguard.tf`) are inserted by rule *id* at write time, so
# their position is invisible to `plan` exactly like the matrix's own rules. Each one names the rule it
# must precede; the table is exhaustive on purpose — a `wireguard:` comment present on the device but not
# listed here is itself a violation, so editing a comment cannot silently retire its assertion.
WIREGUARD_COMMENT_PREFIX = "wireguard:"
WIREGUARD_ANCHORS = (
    # (the accept's comment prefix, the anchor it must precede — matched on comment, then on log-prefix)
    ("wireguard: the tunnel endpoint on the WAN", "defconf: drop all not coming from LAN"),
    ("wireguard: the tunnel's resolver", "defconf: drop all not coming from LAN"),
    ("wireguard: the WiFi class may reach the tunnel endpoint", "MTX-IOT>ROUTER "),
)

# Criteria that narrow a rule below "everything": if an accept has none of them it is a blanket accept.
NARROWING = (
    "connection-state",
    "connection-nat-state",
    "ipsec-policy",
    "dst-address",
    "src-address",
    "src-mac-address",
    "dst-address-list",
    "src-address-list",
    "dst-port",
    "src-port",
    "protocol",
    "in-interface",
    "in-interface-list",
    "out-interface",
    "out-interface-list",
    "in-bridge-port-list",
    "out-bridge-port-list",
)


def load_creds() -> dict[str, str]:
    for path in CREDS_FILES:
        if not os.path.exists(path):
            continue
        env: dict[str, str] = {}
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
        if env.get("ROS_USERNAME") and env.get("ROS_PASSWORD"):
            return env
    sys.exit("matrix-order-check: no router credentials found (looked in: %s)" % ", ".join(CREDS_FILES))


def fetch_rules() -> list[dict]:
    from librouteros import connect

    creds = load_creds()
    api = connect(
        username=creds["ROS_USERNAME"],
        password=creds["ROS_PASSWORD"],
        host=ROUTER_HOST,
        port=ROUTER_PORT,
        timeout=20,
    )
    return [dict(r) for r in api("/ip/firewall/filter/print")]


def is_blanket_accept(rule: dict) -> bool:
    if str(rule.get("action", "")) != "accept":
        return False
    return not any(rule.get(k) not in (None, "", "False") for k in NARROWING)


def describe(rule: dict) -> str:
    return (
        f"id={rule.get('.id')} chain={rule.get('chain')} action={rule.get('action')} "
        f"prefix={rule.get('log-prefix') or '-'} comment={rule.get('comment') or '-'}"
    )


def find_anchor(chain_rules: list[dict], anchor: str) -> int | None:
    """Index of the rule an accept must precede: matched on `comment`, then on `log-prefix`.

    A matrix rule is identified by its log-prefix (it has a comment too, but the prefix is the stable
    half); the defconf drop is identified by the comment the device reports, which is the same string the
    data source in `wireguard.tf` filters on — so both places fail together if it is ever renamed.
    """
    for i, r in enumerate(chain_rules):
        if anchor in str(r.get("comment") or ""):
            return i
        if str(r.get("log-prefix") or "").startswith(anchor):
            return i
    return None


def check(rules: list[dict]) -> tuple[list[str], list[str]]:
    """Return (violations, notes)."""
    violations: list[str] = []
    notes: list[str] = []

    matrix = [r for r in rules if str(r.get("log-prefix", "")).startswith(MATRIX_PREFIX)]
    by_chain: dict[str, list[dict]] = {}
    for r in rules:
        by_chain.setdefault(str(r.get("chain")), []).append(r)

    # 1. at most once per prefix
    seen: dict[str, int] = {}
    for r in matrix:
        seen[str(r.get("log-prefix"))] = seen.get(str(r.get("log-prefix")), 0) + 1
    for prefix, count in sorted(seen.items()):
        if count > 1:
            violations.append(f"[duplicate] {count} rules carry log-prefix {prefix!r} — a second judgement")

    # 2. below the connection-tracking accept of its own chain
    for chain, chain_rules in by_chain.items():
        ct_index = None
        for i, r in enumerate(chain_rules):
            if str(r.get("action")) == "accept" and "established" in str(r.get("connection-state") or ""):
                ct_index = i
                break
        if ct_index is None:
            if any(str(r.get("log-prefix", "")).startswith(MATRIX_PREFIX) for r in chain_rules):
                violations.append(f"[anchor missing] chain {chain!r} has matrix rules but no connection-tracking accept")
            continue
        for i, r in enumerate(chain_rules):
            if not str(r.get("log-prefix", "")).startswith(MATRIX_PREFIX):
                continue
            if i < ct_index:
                violations.append(
                    f"[above connection tracking] {describe(r)} sits at position {i + 1} of chain {chain!r}, "
                    f"above the established/related accept (position {ct_index + 1}) — reply packets would be denied"
                )

    # 3. blanket accepts shadowing the matrix (checked chain-wide: matrix rules are appended last)
    for chain, chain_rules in by_chain.items():
        for i, r in enumerate(chain_rules):
            if is_blanket_accept(r):
                violations.append(
                    f"[blanket accept] {describe(r)} at position {i + 1} of chain {chain!r} is not narrowed — "
                    "it accepts what the matrix is meant to judge"
                )

    # 4. the WireGuard accepts, above the drops they must precede
    input_rules = by_chain.get("input", [])
    present = [
        prefix
        for prefix, _ in WIREGUARD_ANCHORS
        if any(str(r.get("comment") or "").startswith(prefix) for r in input_rules)
    ]
    if not present:
        # The same courtesy the matrix rules get: before the change is applied the rules legitimately do
        # not exist, and a check that cries wolf on day zero is a check nobody keeps.
        notes.append("no wireguard endpoint accepts on the device yet (expected until wireguard.tf is applied)")
    else:
        notes.append(f"{len(present)}/{len(WIREGUARD_ANCHORS)} wireguard accept group(s) present — placement asserted")
        listed = tuple(prefix for prefix, _ in WIREGUARD_ANCHORS)
        for prefix, anchor in WIREGUARD_ANCHORS:
            hits = [i for i, r in enumerate(input_rules) if str(r.get("comment") or "").startswith(prefix)]
            if not hits:
                violations.append(
                    f"[wireguard missing] no input rule carries the comment {prefix!r} — expected by "
                    "terraform/routeros/wireguard.tf (another group is present, so the file is applied)"
                )
                continue
            idx = find_anchor(input_rules, anchor)
            if idx is None:
                violations.append(
                    f"[wireguard anchor missing] nothing in the input chain matches {anchor!r}, so the "
                    f"placement of {prefix!r} could not be measured"
                )
                continue
            for i in hits:
                if i > idx:
                    violations.append(
                        f"[wireguard below its anchor] {describe(input_rules[i])} sits at position {i + 1} of "
                        f"the input chain, below {anchor!r} (position {idx + 1}) — it will never match"
                    )
        for i, r in enumerate(input_rules):
            comment = str(r.get("comment") or "")
            if comment.startswith(WIREGUARD_COMMENT_PREFIX) and not comment.startswith(listed):
                violations.append(
                    f"[wireguard unasserted] {describe(r)} carries a `wireguard:` comment that "
                    "WIREGUARD_ANCHORS does not name — its placement is unchecked"
                )

    if not matrix:
        notes.append("no matrix rules present yet (expected while phase 1 is unapplied)")
    else:
        notes.append(f"{len(matrix)} matrix rule(s) present: " + ", ".join(sorted(str(r.get('log-prefix')) for r in matrix)))
    return violations, notes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true", help="print nothing unless the invariant is violated")
    args = ap.parse_args()

    try:
        rules = fetch_rules()
    except Exception as exc:  # noqa: BLE001 — any failure to measure is exit 2, not a policy verdict
        print(f"matrix-order-check: could not read the router: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2

    violations, notes = check(rules)

    if violations:
        print("# firewall matrix — placement invariant VIOLATED")
        for v in violations:
            print(f"  ✗ {v}")
        print("")
        print("  The chain as measured (position, chain, action, prefix, comment):")
        for i, r in enumerate(rules, 1):
            print(f"    {i:>3} {str(r.get('chain')):8s} {str(r.get('action')):20s} {str(r.get('log-prefix') or '-'):16s} {r.get('comment') or '-'}")
        return 1

    if not args.quiet:
        print("# firewall matrix — placement invariant holds")
        for n in notes:
            print(f"  ✓ {n}")
        print("  chain as measured:")
        for i, r in enumerate(rules, 1):
            print(f"    {i:>3} {str(r.get('chain')):8s} {str(r.get('action')):20s} {str(r.get('log-prefix') or '-'):16s} {r.get('comment') or '-'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
