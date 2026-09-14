# RouterOS / network-gear IaC — CI-run OpenTofu

Layer 1 of the overhaul's IaC layering (`.tf` here → VMs via `bpg/proxmox` later →
apps via ArgoCD, which stays the only GitOps controller). The RB5009's
configuration is declared in this directory and applied by GitHub Actions on
merge.

This is the delivery vehicle [decision Q13](../README.md) chose: **CI-run
OpenTofu**, not Crossplane. Wrapping `tofu` in a Crossplane `Workspace` buys
opaque state, a fringe code path, and a controller that retries forever when
something is wrong; a reviewed plan + a CI apply is the same guarantee with a
readable trail. The earlier Crossplane attempt (PR #31) is superseded — the HCL
survives here, as a real module.

Companion documentation lives in the notes vault
(`home-production-overhaul/`): the plan, the device tracker, the decision
register, and `access-and-change-control` — which is the authority for
everything below. If this file and that note disagree, the note wins.

## Layout

| Path | What |
|---|---|
| `routeros/` | The RB5009 module. Stage 1 = additive groundwork only (see its README) |
| `routeros/backend.tf` | Partial S3 backend config — values come from `TF_STATE_*` at init time |
| `routeros/backend-kubernetes.tf.example` | The alternative state backend, ready to swap in |
| `secrets/enc.routeros-ci.env` | sops-encrypted CI credentials (dotenv), only if path **(b)** below is used |

Planned siblings, not built yet: `crs326/`, `crs804/`, `cloudflare/`, `compute/`
(Phase 1–2 of the plan). They land when their phase opens, each as its own
reviewed PR.

## The runner contract

`runs-on: gha-runner-scale-set-hnatekmarorg`, **the on-prem ARC scale set** —
not a GitHub-hosted runner. Two reasons, both structural:

1. The RouterOS API is address-bound to the LAN subnets and is not
   internet-exposed. A cloud runner simply cannot reach `172.16.100.1:8728`;
   publishing the API to fix that is a much worse idea than the runner choice.
2. The runner lives in the devops cluster, which the agent has no write access
   to. The split is therefore real: the agent authors PRs, the pipeline holds the
   credential and applies.

The runner pod also reaches the internet through a proxy (ARC `proxy` values in
`Hnatekmar/bootstrap-kubernetes`), so every workflow sets `NO_PROXY` for the LAN
ranges. If the proxy value gains a `noProxy` entry pointing at the same ranges,
the workflow-level `NO_PROXY` can go away.

## The credential contract

Exactly two RouterOS identities are involved, and which one a job gets depends on
whether that job can change the device:

| Role | RouterOS user | Policy | Used by |
|---|---|---|---|
| `read` | `agent-ro` | `api,read,test` (**no** `sensitive` — keys/PSKs must not be readable) | plan-on-PR, nightly drift |
| `write` | `iac` | `api,read,write,test` | apply-on-merge only |

`scripts/tofu-ci.sh` is the only place that resolves credentials; it maps the role
pair onto `ROS_USERNAME`/`ROS_PASSWORD` (what the provider reads) and never prints
a value — only key names and their presence.

| Variable | Purpose |
|---|---|
| `ROS_READ_USERNAME`, `ROS_READ_PASSWORD` | role `read` |
| `ROS_WRITE_USERNAME`, `ROS_WRITE_PASSWORD` | role `write` |
| `ROS_HOSTURL` | `api://172.16.100.1:8728` (plaintext API: TLS on 8729 has no usable certificate) |
| `TF_STATE_BUCKET`, `TF_STATE_ENDPOINT`, `TF_STATE_KEY`, `TF_STATE_REGION` | s3 backend |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | s3 backend credentials (MinIO keys) |
| `TF_STATE_BACKEND` | `s3` (default) or `kubernetes` |
| `SOPS_AGE_KEY` / `SOPS_AGE_KEY_FILE` | only for path (b) |

The values get to the runner in one of two ways — **(a)** is preferred, because it
keeps exactly one copy of the credentials and puts no key material in a pod:

**(a) Cluster Secret mounted into the runner pod.** A `SopsSecret` (the repo's
existing sops flow, `scripts/encrypt.sh`) in the `arc-systems` namespace holding
the four `ROS_*` pairs plus the state keys, mounted via
`template.spec.containers[0].envFrom` in the scale-set values
(`Hnatekmar/bootstrap-kubernetes`). Nothing in this repo changes; the workflows
already read the environment. This is also the shape the estate is moving to
anyway (`Bao → ExternalSecrets → the runner pod`).

**(b) sops file in this repo + an age key in the runner.** Used when the runner
values cannot be touched yet:

```bash
# the plaintext source of truth is gitignored, mode 600, never committed
install -m 600 /dev/null terraform/secrets/routeros-ci.env
"$EDITOR" terraform/secrets/routeros-ci.env     # ROS_READ_*, ROS_WRITE_*, TF_STATE_*, AWS_*

sops --encrypt --age age1t9wspfgy0nxrc9d3frmp85g4d5ug6ksf66pv68ycptv0fwsxq9fqxuhma9 \
     --input-type dotenv --output-type dotenv \
     terraform/secrets/routeros-ci.env > terraform/secrets/enc.routeros-ci.env
```

(the recipient is the estate one already used by `devops/argocd/secrets/enc.*.yaml`).
The workflow decrypts it in-process, so decrypted values never reach disk, an
artifact, or a log line.

## The state contract

State is the one thing that must outlive the runner pod, so it needs a remote
backend. Default (**Q8**): **S3 with in-bucket locking** (`use_lockfile`, OpenTofu
≥ 1.10 — no DynamoDB-style lock service to be down) against **MinIO on the devops
cluster**, path-style, with the STS/IAM validation calls skipped since MinIO does
not implement them.

Checked on 2026-09-14: `minio.hnatekmar.xyz` answered **502** and its PV points at
the stale NFS server `.88.25` (the same staleness the plan already flags for
`devops-cluster`). Until that is repaired and a bucket + key exist, the plan and
apply jobs skip instead of failing (see the arming switch below).

Alternative: the **`kubernetes` backend** (`backend-kubernetes.tf.example`) stores
state in a Secret in the devops cluster. No MinIO dependency, less moving parts —
but state becomes unreadable while the cluster is down, which is exactly the
break-glass property Q8 chose S3 for. It is also the cheaper prerequisite (a Role
for the runner's ServiceAccount instead of fixing MinIO), so the trade is worth an
explicit decision rather than a drift.

## The workflows

| Workflow | Trigger | Role | Does |
|---|---|---|---|
| `tf-plan.yml` | PR touching `terraform/**`, manual | `read` | `fmt -check`, `validate`, `plan`; posts the plan as a PR comment |
| `tf-apply.yml` | push to `main` touching `terraform/**`, manual | `write` | `plan -out` then `apply` of that exact plan; run summary + 30-day artifact |
| `tf-drift.yml` | nightly 03:30 UTC, manual | `read` | `plan -detailed-exitcode`; opens/updates/closes the `routeros-drift` issue |

Drift means *the device disagrees with state*, so the nightly job first checks that
state exists at all: an unapplied repository (empty state) is reported as "nothing to
drift from" instead of as drift. Otherwise the 20 stage-1 objects would look like drift
every night until the first apply, and a noisy alert is a dead alert.

**Arming switch.** `tf-apply` and `tf-drift` do nothing until the repository
variable **`ROUTEROS_CI_ENABLED`** is `true`; they log that they skipped and stay
green. That is deliberate: this pipeline can be merged and reviewed before the
bootstrap exists, and merging a `terraform/**` change cannot produce a surprise
apply. Once armed, a missing credential is a hard failure instead of a silent
skip.

**Review gates, in order:** branch protection requires a review on `main`;
`tf-plan` shows the diff on the PR; the `routeros-production` environment (create
it with Martin as required reviewer) holds the apply for a second, explicit
approval; `tf-apply` re-plans before applying so it can only ever apply the plan
it printed.

## One-time bootstrap (Martin — the honest edge of "everything is IaC")

| # | Step | Notes |
|---|---|---|
| 1 | RouterOS users on the RB5009: `iac` (`api,read,write,test`) and `agent-ro` (`api,read,test`) | Q1; commands in `access-and-change-control.md`. Read user must **not** carry `sensitive` |
| 2 | Credentials reach the runner: path (a) cluster Secret, or path (b) sops file + age key | see above |
| 3 | State store: MinIO bucket (`tofu-state`) + a dedicated access key | Q8. MinIO must be healthy first — it answers 502 today. Or choose the `kubernetes` backend |
| 4 | Repository variables: `TF_STATE_BUCKET`, `TF_STATE_ENDPOINT`, optional `TF_STATE_KEY`/`ROS_HOSTURL` | Settings → Variables |
| 5 | Repository variable `ROUTEROS_CI_ENABLED=true` once 1–3 hold | the arming switch |
| 6 | Environment `routeros-production` with Martin as required reviewer | the second gate on apply |

Steps 1–3 are bootstrap exceptions recorded in the notes; when one becomes
automatable it moves into IaC and the manual line is deleted.

## Verifying a plan yourself (reviewer recipe)

Reproduces exactly what CI computes, read-only, from any LAN host:

```bash
git clone git@github.com:hnatekmarorg/devops-cluster.git && cd devops-cluster
cp -r terraform/routeros /tmp/routeros-check && cd /tmp/routeros-check
rm backend.tf                     # local state; this is a plan, nothing is applied
export ROS_HOSTURL=api://172.16.100.1:8728
set -a; . /path/to/agent-ro.env; set +a        # or the same values by hand
tofu init -input=false
tofu plan -input=false -lock=false -no-color
```

Stage 1 must always report **`Plan: 20 to add, 0 to change, 0 to destroy`** — 5
VLAN interfaces, their 5 gateway addresses, and 10 firewall address-list entries.
Anything else (a change, a destroy) is a bug in the module, not a router state to
accept.

Evidence, 2026-09-14 with `agent-ro`: `board_name = RB5009UG+S+`,
`routeros_version = 7.12.1 (stable)`, `interface_count = 14`,
`existing_addresses = [ether2 -> 172.16.100.1/24, sfp-sfpplus1 -> 172.16.101.1/24,
t-mobile -> 78.80.33.35/32]`, plan `20 to add, 0 to change, 0 to destroy`.

## Not here yet, on purpose

- **Stage 2+**: bridge VLAN filtering, tagged ports, DHCP servers, firewall rules.
  Each is its own reviewed stage, because each one can cut connectivity.
- **Adopting existing objects** (`import {}` blocks for the current bridge,
  addresses, DHCP, NAT) — Phase 2 of the plan, once the baseline is written down.
- **Switch config** (CRS326/CRS804/CSS610) and **Cloudflare DNS** — same pattern,
  separate modules, separate PRs.
- **`netmap` collector** — consumes these APIs, does not live here.
