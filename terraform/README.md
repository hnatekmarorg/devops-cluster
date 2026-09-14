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

| Variable | Purpose | Where it lives |
|---|---|---|
| `ROS_READ_USERNAME`, `ROS_READ_PASSWORD` | role `read` | **repository secret** |
| `ROS_WRITE_USERNAME`, `ROS_WRITE_PASSWORD` | role `write` | **environment secret** (`routeros-production`) |
| `ROS_HOSTURL` | `api://172.16.100.1:8728` (plaintext API: TLS on 8729 has no usable certificate) | repository variable |
| `TF_STATE_BUCKET`, `TF_STATE_ENDPOINT`, `TF_STATE_KEY`, `TF_STATE_REGION` | s3 backend | repository variable |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | s3 backend credentials (MinIO key) | **repository secret** |
| `TF_STATE_BACKEND` | `s3` (default) or `kubernetes` | repository variable |
| `SOPS_AGE_KEY` / `SOPS_AGE_KEY_FILE` | only for path (b) below — unused today | — |

The delivery path **in use** is (c): role-scoped GitHub secrets, mapped explicitly
into the job environment by each workflow. Why not the alternatives:

**(a) Cluster Secret mounted into the runner pod** (what Q14's default implies) —
rejected: in ARC, injecting it means restating the runner container definition in
`Hnatekmar/bootstrap-kubernetes` (image pin included), and, decisively, **one mounted
secret hands *both* identities to *every* job**, including PR-triggered plan jobs. A pull
request could then read the write password. That breaks the property this whole module is
built around, so the mount can only ever carry the read pair — at which point it is doing
the same job as a repository secret with more moving parts.

**(b) sops file in this repo + an age key in the runner** — kept documented and the wrapper
still supports it, for when the estate standardizes on key-based delivery:

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

**(c) Role-scoped GitHub secrets (in use).** Repository-level: the read identity and the
state key — everything plan and drift need. Environment-level (`routeros-production`):
the write identity, so it exists only in the apply job you approve. The wrapper models
this as roles, so the workflow files decide what a job can see and the script never has
to guess.

Residual risk worth stating: the state key is repository-level, and `use_lockfile` means
even a plan writes to the bucket, so a same-repo PR job could in principle delete the
state object. It cannot change the router (no write credential) and state is rebuildable
by re-import, but it is why `main` stays review-gated and forks are excluded from the
plan job outright.

## The state contract

State is the one thing that must outlive the runner pod, so it needs a remote
backend. Default (**Q8**): **S3 with in-bucket locking** (`use_lockfile`, OpenTofu
≥ 1.10 — no DynamoDB-style lock service to be down) against **MinIO on the devops
cluster**, path-style, with the STS/IAM validation calls skipped since MinIO does
not implement them.

**Status (2026-09-14):** MinIO was returning 502 earlier the same day (PV on the stale
NFS server `.88.25`) and is **healthy again** — `health/live` and `health/cluster` answer
200, the S3 API answers, and it advertises `x-amz-bucket-region: europe`. Two consequences
are baked into the workflows: sign with region **`europe`**, and default the endpoint to the
**in-cluster service** (`http://minio.minio.svc.cluster.local:9000`, the same plain-HTTP
path the registry cache uses) rather than the public hostname — `443/tcp` is forwarded to
the edge Caddy box, so `console-minio.hnatekmar.xyz` (S3 API) and `minio.hnatekmar.xyz`
(console) are reachable from the internet. Acceptable as a break-glass path from a LAN
laptop, not as the default for router state.

Still needed before the plan/apply jobs do anything: the **bucket** (`tofu-state`) and a
**key pair scoped to it**. Until those exist the jobs skip with an explanation instead of
failing (see the arming switch below).

Two values are now measured rather than assumed, and both are baked into the workflows
and `scripts/tofu-ci.sh`:

- **Region `europe`** — MinIO's advertised bucket region. Because `europe` is not a valid
  AWS region name, the SDK rejects it before any request is made (`invalid AWS Region:
  europe`); the backend therefore sets `skip_region_validation=true` next to its other
  skip flags. Signing with a real AWS region name would mean signing with something MinIO
  does not advertise.
- **Endpoint = the in-cluster service** (`http://minio.minio.svc.cluster.local:9000`), the
  same plain-HTTP path the registry cache uses, so state never travels over the public
  ingress. `https://console-minio.hnatekmar.xyz` stays documented as the LAN break-glass
  path (and is what verified the bucket + policy from the Hermes host).

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

| # | Step | Status / notes |
|---|---|---|
| 1 | RouterOS read user `agent-ro` | **exists and is in use.** Two fixes owed: **drop `sensitive`** from the `read` group (it currently returns keys/PSKs on read) and narrow the policy to the agreed `api,read,test` — one command per device |
| 2 | RouterOS write user `iac` (`api,read,write,test`) | **after the merge** (agreed): the write identity only gates apply, which is inert until armed |
| 3 | Repository **secrets**: `ROS_READ_USERNAME`, `ROS_READ_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | the read identity + the state key. Nothing else is needed for plan-on-PR. Sources: `/root/network-migration/credentials/routeros.env` and `minio.env` on the Hermes host (root-only) |
| 4 | State store: `tofu-state` bucket + scoped key | ✅ **done and verified** — `init`+`plan` green, lock object written/released, cross-bucket access denied; policy in `terraform/secrets/` |
| 5 | Repository **variables**: `TF_STATE_BUCKET`, `TF_STATE_ENDPOINT`, `TF_STATE_REGION`, `ROS_HOSTURL` | ✅ **done** (`tofu-state`, in-cluster endpoint, `europe`, `api://172.16.100.1:8728`) |
| 6 | Environment `routeros-production` (required reviewer: Martin) + environment **secrets** `ROS_WRITE_USERNAME`, `ROS_WRITE_PASSWORD` | after step 2; the second gate on apply |
| 7 | Repository variable `ROUTEROS_CI_ENABLED=true` | **the arming switch** — last, once 2, 3 and 6 hold. Before that, apply and drift log that they skipped and stay green |

Steps 1–2 and 6 are bootstrap exceptions recorded in the notes; when one becomes
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
