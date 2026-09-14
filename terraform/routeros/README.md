# `routeros/` — the RB5009 module

Stage 1: **additive groundwork, zero behavioural change.** Contracts (runner, credentials, state,
workflows) live in [`../README.md`](../README.md); the measured wiring and the VLAN design in
[`../docs/network-wiring.md`](../docs/network-wiring.md).

## What stage 1 creates

- **5 VLAN interfaces** — no ports assigned, so they carry nothing until a later stage makes the
  bridge VLAN-aware: `vlan10-mgmt`, `vlan30-lab`, `vlan40-srv`, `vlan60-vpn`, `vlan70-iot`
- **their gateway addresses**, carrying the class prefix with the address at the `.1` of the host
  area: `172.16.10.1/20`, `172.16.30.1/20`, `172.16.40.1/19`, `172.16.96.1/20`, `172.16.70.1/20`
- **address lists** (`mgmt-nets`, `lab-nets`, `srv-nets`, `iot-nets`, `vpn-nets`, `svc-vips`,
  `lan-nets`, `ai-compute`, `wan-restricted`) — referenced by no rule yet, so no policy changes

It refuses to touch, by construction: the bridge (`vlan-filtering`, tagged ports), DHCP servers,
firewall rules, NAT, routes — and every object that already exists on the device. Those are
adopted with `import {}` blocks in their own waves (`bridge.tf` = the bridge domain, `wan.tf` =
the PPPoE client) rather than recreated.

## The blocks

| Class | Subnet | Host area | Notes |
|---|---|---|---|
| mgmt | `172.16.0.0/20` | `.10.x` | admin plane + out-of-band |
| lab | `172.16.16.0/20` | `.30.x` | AI compute, sandboxes |
| srv | **`172.16.32.0/19`** | `.40.x` | the keepers — **MetalLB pool `.48.1–.63.254` inside it** |
| iot | `172.16.64.0/20` | `.70.x` | the whole WiFi segment |
| vpn | `172.16.96.0/20` | `.96.x` | VPN zone (VID 60); tunnel clients routed in from `172.16.112.0/20` |

`compat` (`172.16.100.0/24`) drains last. `trusted` (20) and `guest` (50) are retired and stay
unallocated. One subnet per class, sized by its block: the point is that the space is
*allocatable* (pool and nodes in one subnet, so MetalLB stays in L2), not merely documented.

## Files

| File | What |
|---|---|
| `versions.tf` | OpenTofu ≥ 1.10 (s3 `use_lockfile`); provider pinned **exactly** — it manages the device behind every VLAN, and its schemas shift between minor versions |
| `backend.tf` | partial S3 backend; every value injected at init by `scripts/tofu-ci.sh` |
| `providers.tf` | empty on purpose — `ROS_*` env carries endpoint and credentials |
| `main.tf` | the stage-1 resources |
| `smoke.tf` | read-only data sources: every plan proves connectivity + credentials and prints a device fingerprint |
| `bridge.tf` / `wan.tf` | the adoption waves (import-only today) |
| `outputs.tf` | the plan's evidence: board/version, VLANs, address lists, current addresses |

## Traps worth not rediscovering

- `api://…:8728` is the working transport; `:8729` fails the TLS handshake — no certificate is
  bound to `api-ssl`. TLS later, with a cert, then `ROS_INSECURE=false` + `ROS_CA_CERTIFICATE`.
- **`/export` does not exist over the API.** A 0-byte capture is not a backup; restore-capable
  backups need an admin account and a human.
- read users must not carry `sensitive`, or reads return keys and PSKs in plaintext.
- **One object, one owner.** Merging two waves that both declared the same resource fails the plan
  job with `Duplicate resource/import configuration` — loudly, before anything reaches a device.
  That is the gate working, not a merge problem to route around.
- The provider (1.99.1) does not know every field this hardware reports (`trusted_ra`,
  `trusted_dhcpv6`, `managed`). When it learns them, a plan may show changes — not drift.
- An adoption wave must plan **zero changes**. If it shows one, the config is missing an attribute
  the device has (`comment = "defconf"` was exactly that case).

## Roadmap

| Stage | Contents | Gate |
|---|---|---|
| 1 (this) | VLAN interfaces, gateways, address lists | plan = adds only, `0 change / 0 destroy` |
| 1b | adoption waves: WAN objects, bridge domain | plan = imports only, zero changes |
| 2 | WAN out of the bridge; `vlan-filtering` + escape port | reviewed plan + a cable-swap test |
| 3 | firewall matrix (deny-by-default east-west), `wan-restricted` log-only, WireGuard | per-VLAN reachability matrix verified |
| 4 | compat retirement | plan clean twice, drift green |
