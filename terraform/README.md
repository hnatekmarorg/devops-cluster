# RouterOS IaC — CI-run OpenTofu

The RB5009's configuration is declared here and applied by GitHub Actions on merge. Delivery
model: **CI-run OpenTofu** (decision Q13), not Crossplane — a reviewed plan plus a CI apply gives
the same guarantee with a trail you can read.

**Read the human layer first.** [`docs/human/README.md`](docs/human/README.md) has the readable
map, the network schema and the runbooks, written in Simplified Technical English. The measured
working notes are the archive in [`docs/agent/`](docs/agent/) — start with the wiring and the VLAN
design: [`docs/agent/network-wiring.md`](docs/agent/network-wiring.md) (with
[`network-wiring.svg`](docs/agent/network-wiring.svg) and
[`network-map-current.svg`](docs/agent/network-map-current.svg), as-is vs proposed). Port-by-port
assignment: [`docs/agent/vlan-port-assignment.md`](docs/agent/vlan-port-assignment.md). The steps
only a human can do:
[`docs/agent/router-bootstrap-runbook.md`](docs/agent/router-bootstrap-runbook.md). The plan,
decision register and traps: the notes vault, `home-production-overhaul/`.

## Layout

| Path | What |
|---|---|
| `routeros/` | the RB5009 module — stage 1 is additive groundwork only (see its README) |
| `docs/human/` | the readable layer — map, schema, runbooks (Simplified Technical English) |
| `docs/agent/` | the measured working notes — wiring, VLAN carve, port table, runbook, maps |
| `secrets/` | the state-key policy; the sops delivery path (unused today) |
| `../scripts/tofu-ci.sh` | the wrapper: role → credentials, backend config, nothing else |

Not built yet, on purpose: `crs326/`, `crs804/`, `cloudflare/`, `compute/` — each lands as its own
reviewed PR when its phase opens.

## Runner

`runs-on: gha-runner-scale-set-hnatekmarorg` — the on-prem ARC scale set, because the RouterOS API
is LAN-bound and a cloud runner cannot reach it. One measured fact worth keeping: that runner lives
in **the other on-prem cluster** (`Hnatekmar/bootstrap-kubernetes`), *not* the devops cluster where
MinIO runs — they are separate estates. The runner egresses through a proxy, so workflows set
`NO_PROXY` for the LAN ranges.

## Credentials

| Role | RouterOS user | Policy | Used by |
|---|---|---|---|
| read | `agent-ro` | `api,read,test` — **no** `sensitive` | plan-on-PR, nightly drift |
| write | `iac` | `api,read,write,test` | apply-on-merge only |

`ROS_READ_*` are repository secrets; `ROS_WRITE_*` live on the **`routeros-production` environment**,
so the write identity exists only in the apply job a human approved. That is the whole point: a
PR-triggered plan job can never read the write password, which is exactly why "mount one secret in
the runner pod" was rejected. The sops path in `secrets/` stays supported but is unused.

## State

| Setting | Value |
|---|---|
| Backend | S3 with in-bucket locking (`use_lockfile`) — no lock service that can be down |
| Endpoint | `http://172.16.100.148:9000` — **MinIO on the NAS**, on the LAN |
| Bucket | `tofu-state`, key pair scoped to it (policy in `secrets/`) |
| Region | `europe` (what MinIO advertises; needs `skip_region_validation=true`) |

Two properties, both measured rather than assumed: CI reaches the store over the plain LAN — **no
DNS, no ingress, no hairpin through the router** — and it depends on **no cluster at all**, so the
state stays readable when the devops cluster is down. That break-glass property is why Q8 chose S3.

Trap: the devops cluster runs its own `minio` namespace that receives no traffic and whose PVC is
failing writes. It is a leftover from an August install, not the live store — check who consumes
`minio.minio.svc.cluster.local` before removing it.

## Workflows

| Workflow | Trigger | Role | Does |
|---|---|---|---|
| `tf-plan.yml` | PR touching `terraform/**`, manual | read | fmt, validate, plan; posts the plan as a PR comment |
| `tf-apply-routeros.yml` | push to `main` touching `terraform/routeros/**`, manual | write | `plan -out`, then apply of that exact plan, against the RB5009 |
| `tf-apply-crs326.yml` | push to `main` touching `terraform/crs326/**`, manual | write | same, against the CRS326 |
| `tf-drift.yml` | nightly 03:30 UTC, manual | read | `plan -detailed-exitcode`; opens/updates/closes the drift issue |

Drift means *the device disagrees with state*, so the nightly job checks first that state exists at
all: an unapplied repository is reported as "nothing to drift from", not as drift. A noisy alert is
a dead alert.

**Arming switch.** `tf-apply` and `tf-drift` do nothing until the repository variable
**`ROUTEROS_CI_ENABLED=true`**. So this pipeline can be reviewed and merged before the bootstrap
exists, and merging a `terraform/**` change cannot produce a surprise apply. Once armed, a missing
credential becomes a hard failure instead of a silent skip.

**A merge is the authorization to apply** (Martin, 2026-09-15). The plan on the PR is what gets
reviewed, so the environments no longer hold a second approval click — the click added no information
the plan had not already given. The environments stay, for the two properties that are not about the
click: they scope the device's **write credential**, and their protected-branches policy restricts
deployment to `main` — reviewed code only.

Review gates, in order: branch protection on `main` (PR + 1 approval + conversation resolution), the
plan comment on the PR, and the apply re-planning so it can only apply what it printed. Because the
merge authorizes, each apply is triggered by changes to *its own* module (`terraform/routeros/**`,
`terraform/crs326/**`) — the applied scope equals the reviewed scope, and a shared module added under
`terraform/` must be listed in both workflows' `paths:`.

## Bootstrap still outstanding (Martin)

| # | Step |
|---|---|
| 1 | `read` group → `api,read,test` on all three devices (drops `sensitive`: reads currently return keys/PSKs) |
| 2 | NTP on both switches — both are `enabled=no`, which is what let the CRS326 drift nine days |
| 3 | `iac` write user on the RB5009, then the `routeros-production` environment + `ROS_WRITE_*` secrets |
| 4 | Pull the three devices' backups **off** the devices |
| 5 | `ROUTEROS_CI_ENABLED=true` — last, once 3 holds |

## Reviewing a plan yourself

```bash
git clone git@github.com:hnatekmarorg/devops-cluster.git && cd devops-cluster
cp -r terraform/routeros /tmp/routeros-check && cd /tmp/routeros-check
rm backend.tf                                   # local state; this is a plan, nothing is applied
export ROS_HOSTURL=api://172.16.100.1:8728
set -a; . /path/to/agent-ro.env; set +a
tofu init -input=false && tofu plan -input=false -lock=false -no-color
```

**Fetch before you branch.** A checkout that predates the last merge proposes *destroying* what a
later PR added — a stale `main` plus one commit plans `8 to destroy` for objects that are live and
healthy. If a plan offers to delete bridge VLAN entries or a bridge port, suspect your tree before
you suspect the device.

**Always expect `0 to change, 0 to destroy`.** Adds are legitimate; a change or a destroy is a bug
in the module, not router state to accept. Today's plan: `11 to import` (the adoption waves) plus
`20 to add` (stage 1).

## Not here yet, on purpose

Switch configuration beyond the CRS326 (CRS804, CSS610, CRS317), Cloudflare DNS, VM lifecycle via
`bpg/proxmox`, and the netmap collector — separate modules, separate PRs. The remaining migration
waves (device moves, firewall policy, compat retirement) each need their own plan, review and
window, because each can cut connectivity. The manual steps are in
[`docs/human/runbooks/`](docs/human/runbooks/).