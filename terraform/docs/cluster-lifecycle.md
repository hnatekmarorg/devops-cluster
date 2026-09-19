# The cluster lifecycle

How a cluster comes into existence, how it goes away, and what is deliberately left alone. The short
version: **a cluster exists when its root exists in `main`.**

```
PR adds    terraform/clusters/<name>/   →  plan on the PR          →  merge  →  provision
PR deletes terraform/clusters/<name>/   →  plan -destroy on the PR →  merge  →  destroy
PR closed without merging               →  nothing at all
```

## Why not "close the PR and the cluster dies"

The review-app pattern is tempting and does not survive contact with this estate, for one reason: **a
merge is a close.** The cluster's ArgoCD wiring has to live in `main`, because the bootstrap hands ArgoCD
a root Application whose `targetRevision` is `HEAD` over `bootstrap/argocd/<cluster>` — so merging the
description would immediately fire the destroy that closing triggers, and destroy the cluster it just
described.

Existence in `main` has no such collision, and it buys something the PR-close version cannot: **the
teardown is reviewed as a `tofu plan -destroy` before it runs**, which is the same rule the device
workflows already state — a merge to `main` is the authorization to apply, so what is reviewed must be
what lands.

Closing a PR without merging provisions nothing and destroys nothing. Fork PRs never see a secret at all.

## Provisioning a new cluster

**Prerequisites first, as their own PR.** Reservations and DNS records live in `terraform/routeros/`, and
they must be **applied** (not merely merged) before the cluster is applied: a node with no reservation
still gets an address — a pool lease, ten minutes long — so the cluster comes up looking fine and then
re-addresses itself. The whole reason to merge the prerequisites separately is that the router apply runs
on its own merge.

**Then the cluster root**, which is four files and a node table:

```
terraform/clusters/<name>/{versions,providers,backend,main}.tf   ← the root
bootstrap/argocd/<name>/cluster-base.yaml                        ← what ArgoCD converges, and the class
```

Merge it, and `tf-apply (clusters)` provisions: `tofu apply` → `bootstrap-cluster.sh` → kubeconfig. The
per-cluster state key is `cluster-<name>/terraform.tfstate`, derived from the directory name.

Manually, the same thing:

```bash
cd terraform/clusters/<name>
TF_STATE_KEY=cluster-<name>/terraform.tfstate ../../../scripts/tofu-ci.sh --role=none init -input=false
TF_STATE_KEY=cluster-<name>/terraform.tfstate ../../../scripts/tofu-ci.sh --role=none apply
./scripts/bootstrap-cluster.sh <name>       # CCM → CRDs → ArgoCD → join secret → root app
./scripts/wire-vault.sh <name>              # vault auth mount + role + policy
./scripts/kubeconfig.sh <name>              # regenerate the credential-free kubeconfig
```

`bootstrap-cluster.sh` and `wire-vault.sh` need **no per-cluster changes** — both take the cluster name
and derive the rest (`auth/kubernetes-<name>`, role `local-<name>`, the `<name>/` vault prefix). The
class (`dev` / `infra`) is the only per-cluster input that decides anything about access, and it lives in
`cluster-base.yaml`.

`--role=none` exists for cluster roots: they authenticate to Proxmox with `PROXMOX_VE_*` and to the state
with `AWS_*`, so there is no role pair to resolve. Before it existed, a cluster apply died at exit 78 with
a message about RouterOS credentials that had nothing to do with the job.

## The SSO kubeconfig

The kubeconfig contains **no credential** — endpoint, public CA, and a `kubelogin` exec block. The
identity lives in Keycloak, which is why it is safe in git and safe to post.

- **In CI**: the apply job writes it to the run's job summary, and if the committed copy no longer matches
  (a rebuild means a new CA) it opens a PR with the refreshed file. That matters because a stale
  kubeconfig fails with `x509: certificate signed by unknown authority` — an error that looks like
  anything but a stale file.
- **In git**: `terraform/clusters/<name>/kubeconfig.yaml`, refreshed by `scripts/kubeconfig.sh <name>`
  after every rebuild. `kubeconfig-comment.yml` posts it as a PR comment whenever it changes.
- **To use it**: install the `kubelogin` plugin (`kubectl oidc-login`), point `KUBECONFIG` at the file,
  and the first call opens a browser. You land as `sso:<your email>` with your Keycloak groups.

Access comes from the **class**, not the kubeconfig: `dev` binds `sso:k8s-dev-*`, `infra` binds
`sso:k8s-infra-*`. Note what that means for the shared OIDC client — the *audience* does not scope a token
to a cluster, so a dev token passes prod's audience check. What separates them is the RBAC class, which is
the axis it was built to be.

## Destroying a cluster

**Merge a PR that deletes the root.** The PR gets a `plan -destroy`, so what will disappear is reviewed
before it does; after the merge the CI job restores the root from the parent commit (a destroy needs the
*configuration*, not just the state), then runs `scripts/teardown-cluster.sh <name> --yes`.

Locally: `./scripts/teardown-cluster.sh <name>` (it asks you to type the cluster name unless `--yes`).

The script does four things `tofu destroy` alone does not:

| step | why |
|---|---|
| **init, then drain Karpenter's claims** | burst VMs are not in the root's state — they belong to Karpenter, a guest of the cluster. Destroy the cluster first and the only thing that could clean them up is gone. Measured: a dev teardown left them and they had to be swept by hand |
| **destroy** | takes the state lock, unlike a plan: writers serialise |
| **sweep for `<name>-*` VMs** | catches Karpenter's orphans when the drain could not run — which is exactly the case of a cluster too broken to answer `kubectl` |
| **optionally unmount the vault** (`--unmount-vault`) | `auth/kubernetes-<name>` outlives the cluster; a rebuild re-wires it, so this is hygiene |

**Deliberately NOT torn down**: the router reservations and DNS records, and the state object. The
reservations are the cluster's fixed identities — keeping them is what makes a rebuild land on the same
names and addresses. Removing them is the reverse of the prerequisites PR and belongs in its own reviewed
PR; deleting the state turns "rebuild" into "discover the VMs still exist".

## What CI needs before it will do anything

The workflows are **unarmed by default** and report what they are missing rather than failing — a PR you
cannot review because CI is red is worse than one that names the missing piece. In practice the preflight
is what tells you, but this is the list:

| what | where | why there and not somewhere else |
|---|---|---|
| `CLUSTER_CI_ENABLED=true` | repository **variable** | the panic button — set it to anything else and merges stop touching infrastructure |
| `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` | repository **secrets** | the **plan's** identity, and it must be **READ-ONLY**. A pull-request job can run code from a same-repo branch, so anything it can reach is reachable by unreviewed code |
| `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` | the **`clusters-production` environment** | the **apply's** identity, which can allocate VMs. Environment-scoped for exactly that reason |
| `TF_STATE_BUCKET`, `TF_STATE_ENDPOINT`, `TF_STATE_REGION` | repository variables | already present for the device roots |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | repository secrets | the state bucket |
| `@Hnatekmar` satisfies CODEOWNERS | repository | review is required on `terraform/`, `charts/`, `bootstrap/` and the lifecycle scripts |

The read-only token is a built-in role, so this is two commands:

```bash
pveum user token add kubernetes@pve terraform-ro --privsep 0
pveum acl modify / --tokens 'kubernetes@pve!terraform-ro' --roles PVEAuditor
```

`PVEAuditor` is `VM.Audit`, `Sys.Audit`, `Datastore.Audit` — enough for the provider to refresh the VM
table, and no `VM.Allocate` / `VM.Config.*` / `VM.PowerMgmt`. If you see `proxmox credentials missing` on
a plan while the apply can reach Proxmox, this is why: they are two different identities on purpose, and
the environment's write token is deliberately invisible to a pull request.

**Two ways this bites silently, both measured:**

1. **A cluster whose state is still local.** CI initialises the S3 backend for `cluster-<name>/…`, so a
   local state is invisible: the plan proposes **creating a second cluster** (same MACs) and a destroy
   reports "0 destroyed" while the VMs keep running. `scripts/teardown-cluster.sh` now refuses in that
   situation and offers `--local-state`; before arming, either migrate the state
   (`tofu init -migrate-state`) or leave that cluster out of CI.
2. **`check_health`.** The module's health gate cannot pass on any cluster with a hostname override
   (7 of 8 checks pass; the failing one is the static-pod naming). The roots set it false, and the module
   now honours it — before that fix it was declared and never wired, so every CI apply would have been
   red on a healthy cluster.



## Known limitations, in the order they will bite

1. **A three-control-plane cluster has a single-point endpoint.** `prod-k8s` resolves to `prod-cp1`. The
   reserved `172.16.48.0/20` has been earmarked for a service VIP since the dev cluster was built and
   nothing claims it yet.
2. **Nothing backs up a cluster** and there is no observability stack in `cluster-base`.
3. **`cluster-base` reports `Application/nginx` and the two `sso-k8s-*` bindings OutOfSync** with an empty
   syncResult. Unexplained and pre-existing.

## The runner

Everything here runs on the one self-hosted runner, and it is a **podman container** on the mgmt host
(`github-runner`, `ghcr.io/actions/actions-runner`), which runs **one job at a time** — so a wedged job
either queues everything behind it or, if it times out, looks like a CI outage.

**The failure mode to recognise** (it has happened more than once): jobs queue forever while the runner
looks healthy. The container is up, the listener process is running, the host is idle — and the *broker
session* is dead, so GitHub sees a runner that heartbeats but never receives work:

```
[RUNNER ERR BrokerServer] Unable to read data from the transport connection: Operation canceled
[RUNNER WARN BrokerServer] Back off 14.133 seconds before next retry. 4 attempt left.
```

**Diagnose** (the runner is a container, so check *inside* it — the host has no `/home/runner`):

```bash
ssh root@172.16.10.202
podman ps                                   # is the container up?
podman logs --tail 40 github-runner         # broker errors?
podman exec github-runner getent hosts broker.actions.githubusercontent.com
podman exec github-runner curl -sS -o /dev/null -w '%{http_code}\n' \
  https://broker.actions.githubusercontent.com/     # 404 is the HEALTHY answer: TLS fine, unauthenticated
```

**Fix** — with no job executing, a restart is safe and is the whole repair:

```bash
podman restart github-runner
```

Then watch a queued run start within seconds. Note what this is *not*: it is not a stale state lock. Plans
run with `-lock=false` by design, and the routeros/Proxmox paths were all reachable when this last
happened. If you are reaching for `tf-unlock`, check the broker first — the symptom is identical and the
cause is not.
