# `routeros/` — RB5009 module

Stage 1 of the network IaC track: **additive groundwork only, zero behavioural
change**. For how this device is wired today — port by port, measured — and the
proposed VLAN carve, see [`../docs/network-wiring.md`](../docs/network-wiring.md). See [`../README.md`](../README.md) for the runner, credential, state
and workflow contracts — this file is about the module itself.

## What this stage creates, and what it refuses to touch

Creates (20 objects on a clean estate):

- 5 VLAN interfaces (`vlan10-mgmt`, `vlan20-trusted`, `vlan30-lab`, `vlan40-srv`,
  `vlan50-guest`) — with **no ports assigned**, so they carry no traffic until a
  later stage makes the bridge VLAN-aware
- the 5 gateway addresses (`172.16.{10,20,30,40,50}.1/24`)
- 10 firewall address-list entries in 9 lists (`mgmt-nets`, `trusted-nets`,
  `lab-nets`, `srv-nets`, `guest-nets`, `vpn-clients`, `lan-nets`, `ai-compute`,
  `wan-restricted`) — referenced by **no rule yet**, so they change no policy

Refuses to touch, by construction: the bridge (`vlan-filtering`, tagged ports),
DHCP servers, firewall rules, NAT, routes, and every object that already exists on
the device. Later stages adopt the existing objects with `import {}` blocks rather
than recreating them.

VLAN numbering and sizing are the Q2 defaults (`.10/.20/.30/.40/.50`, `/24` each);
the VPN zone deliberately has no VLAN — WireGuard clients live on the tunnel
interface's own subnet (`172.16.60.0/24`, stage 3).

## Files

| File | What |
|---|---|
| `versions.tf` | Pins: OpenTofu ≥ 1.10 (s3 `use_lockfile`), provider `terraform-routeros/routeros` `1.99.1` exact |
| `backend.tf` | Partial S3 backend — all values injected at init by `scripts/tofu-ci.sh` |
| `backend-kubernetes.tf.example` | The alternative backend, ready to swap in |
| `providers.tf` | Empty provider block on purpose: `ROS_*` env vars carry endpoint + credentials |
| `variables.tf` | `bridge_interface`, `router_name`, `ai_compute_hosts` |
| `main.tf` | The stage-1 resources |
| `smoke.tf` | Read-only data sources: every plan proves connectivity and credentials, and prints a live fingerprint of the device |
| `outputs.tf` | The plan's evidence: board/version, VLANs + gateways, address-list names, current addresses |

The provider version is pinned **exactly** rather than with `~>`: this module
manages the device that carries every VLAN in the estate, and the provider changes
resource schemas between minor versions. Renovate opens the bump PRs; each one is
reviewed like any other change.

## Traps this module already encodes

- **`api://…:8728` is the working transport.** `apis://…:8729` fails the TLS
  handshake — no certificate is bound to the `api-ssl` service. Move to TLS only
  after a cert is installed, then set `ROS_INSECURE=false` and pin the cert with
  `ROS_CA_CERTIFICATE`.
- **`/export` is not available over the API** at all — a 0-byte capture is not a
  backup. Restore-capable backups are `/system backup save` +
  `/export show-sensitive`, which need an admin account and a human.
- **Read users must not carry `sensitive`**, or reads return keys/PSKs in
  plaintext (a WireGuard private key leaked that way once).
- **RouterOS is at 7.12.1 and the upgrade is pending** (Phase 0). `smoke.tf`
  prints the live version in every plan, so the change is visible in the PR that
  follows it.
- **The bridge is not managed here.** `bridge_interface` only names the parent of
  the new VLANs; making the bridge VLAN-aware is stage 2 and needs its own plan,
  its own review and a stated change window.

## Roadmap for this module

| Stage | Contents | Gate |
|---|---|---|
| 1 (this) | VLAN interfaces, gateways, address lists | `plan` = 20 add / 0 change / 0 destroy, twice |
| 2 | `vlan-filtering` on the bridge + one tagged port; DHCP per VLAN | reviewed plan + cable-swap test from the mgmt VLAN |
| 3 | firewall matrix (deny-by-default east-west), `wan-restricted` log-only, WireGuard | reachability matrix verified per VLAN, phone-off-LTE test |
| 4 | adoption of existing objects (`import {}`), compat segment retirement | `plan` clean ×2 after import, drift job green |
