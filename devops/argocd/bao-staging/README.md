# bao-staging — disposable OpenBao for rehearsing Crossplane auth/policy

**Status: experiment scaffold.** Deployed against a *throwaway* OpenBao in this cluster so nothing here can touch the production identity stack (`bao.hnatekmar.xyz`, managed from `hetzner-k8s`).

## Why

We want to bring the OpenBao *access model* under IaC — a read-only policy for the agent + tighter auth. Before that lands in the repo that owns the live Bao, two things need evidence:

1. **Does a declaratively-managed `AuthBackendRoleSecretID` loop?** Production still carries `roles/approle/hermes-agent-secretid.yaml` with `secretIdNumUses: 0` / `secretIdTtl: 0`. A previous AppRole setup produced enough request volume to overwhelm OpenBao's storage backend (then the **file** backend: millions of small files → inode exhaustion; now migrated to raft). If the reconciler re-issues SecretIDs, that resource type must never be used against production.
2. **Do the policy/role MRs behave** (create once, observe, settle) — so the same YAML can be promoted with only `providerConfigRef` changed.

## Safety properties of this staging instance

- **dev mode**: in-memory, no persistence, no unseal step, fixed root token (`root`) declared in `values.yaml`.
- **No ingress**, `ui: false`, `injector: false`, `csi: false`; reachable only inside the cluster.
- **Nothing real** ever goes in here. Deleting the directory disposes of everything.
- **Structurally isolated from production**: this cluster's Crossplane runs the vault provider but had *no* ProviderConfig for it — the one added here (`bao-staging`) points at `http://openbao.bao-staging.svc:8200`. Production's ProviderConfig (`bao-hnatekmar-xyz`) lives only in `hetzner-k8s`.

## Files

| File | What |
|---|---|
| `bao-staging.yaml` | ArgoCD Application → openbao chart 0.29.4, dev-mode values (sync-wave 2) |
| `values.yaml` | disposable config (see safety properties) |
| `01-credentials.yaml` | `Secret bao-staging-token` (dev root token) for the provider |
| `02-providerconfig.yaml` | Crossplane `ProviderConfig bao-staging` → the staging instance |
| `10-policy-atuin-ro.yaml` | the **intended production** read-only agent policy |
| `20-auth-approle.yaml` | mounts the `approle` auth backend |
| `30-role-atuin-ro.yaml` | AppRole role with the **intended production** TTLs (`num_uses=1`, `ttl=600`) |
| `40-secretid-EXPERIMENT.yaml` | ⚠️ the artefact under test (see header comment in the file) |

## Experiment protocol

**Setup:** wait for `kubectl -n bao-staging rollout status deploy/openbao`, then confirm MRs 10/20/30 are `Ready` (`kubectl -n crossplane-system get policies,backends,authbackendroles`).

**Phase A — control (no SecretID MR present).** Remove `40-secretid-EXPERIMENT.yaml`, let ArgoCD sync, then after ~1 min record a baseline and again 15 min later:

```bash
# provider-side view: how often is the secret-id endpoint hit?
kubectl -n crossplane-system logs deploy/upbound-provider-vault --since=15m | grep -c 'secret-id'

# server-side view: total handled requests (metric prefix may be vault_ or openbao_)
kubectl -n bao-staging exec deploy/openbao -- sh -c \
  'BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root bao read -format=prometheus sys/metrics' \
  | grep -E 'handle_request' | awk '{print $1, $2}'
```

**Phase B — test (SecretID MR present).** Re-add the file, wait for sync, repeat the same two measurements over the same 15-minute window.

**Verdict:**
- `delta_B ≈ delta_A` → the MR settles; `AuthBackendRoleSecretID` is safe to use in production (with `num_uses=1`).
- `delta_B ≫ delta_A`, or MR status oscillating `Creating`/`Ready` (`kubectl -n crossplane-system get -w authbackendrolesecretid atuin-ro-secretid`) → **loop confirmed**: production keeps issuing SecretIDs out-of-band (`bao write -f auth/approle/role/<role>/secret-id`) and the MR type is banned from the production repo.

## Teardown

```bash
rm -rf devops/argocd/bao-staging     # ArgoCD prunes the app + MRs
# or, immediately:
argocd app delete bao-staging --cascade
kubectl -n crossplane-system delete providerconfig bao-staging secret bao-staging-token
```
The staging Bao itself is in-memory: gone as soon as the pod goes.

## Promotion path (after the experiment)

| Staging file | Production change (`hetzner-k8s`) |
|---|---|
| `10-policy-atuin-ro.yaml` | same YAML, `providerConfigRef: bao-hnatekmar-xyz` |
| `30-role-atuin-ro.yaml` | only if the AppRole path survives the experiment; otherwise issue tokens out-of-band |
| — | tighten `hermes/policies/hermes-agent.yaml` from mount-wide CRUD to read-only |
| — | retire `roles/approle/hermes-agent-secretid.yaml` (with an out-of-band replacement issued first) |
| — | update `hermes/README.md` secret registry with `hermes/agents/atuin/*` |

## Findings to carry over regardless of the experiment

- **Audit may not actually be enabled in production.** The chart's default is `server.auditStorage.enabled: false`; the production values set only `auditStorage.storageClass`, which provisions nothing on its own, and audit *devices* are enabled at runtime. Verify with `bao audit list` — if it's empty, the "audited reads" assumption in the access model needs fixing before it is relied on.
- **`server.image.tag: "latest"`** in production values + ArgoCD self-heal = silent upgrades of a one-way storage format. Pin it.
- **No raft snapshot backup path is visible.** Single-node raft on a `local-path` PVC dies with the node. A scheduled `bao operator raft snapshot save` to the NAS is the difference between restoring secrets and rebuilding every credential in the estate.

## Known unknowns

- The exact JSON the upbound vault provider expects in the credential secret (token-only vs `address`+`token`). `{"token": "root"}` is the token-only form; the first reconcile verdict tells us.
