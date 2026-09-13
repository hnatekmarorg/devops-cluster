# bao-staging — disposable OpenBao for rehearsing Crossplane auth/policy

**Status: experiment scaffold.** A *throwaway* OpenBao in this cluster, built to mirror production's storage profile, so nothing here can touch the production identity stack (`bao.hnatekmar.xyz`, managed from `hetzner-k8s`).

## Why

Before the OpenBao access model is brought under IaC in the repo that owns the live Bao, three things need evidence:

1. **Does a declaratively-managed `AuthBackendRoleSecretID` loop?** Production still carries `roles/approle/hermes-agent-secretid.yaml` (`secretIdNumUses: 0`, `secretIdTtl: 0`). A previous AppRole setup generated enough volume to overwhelm OpenBao's storage backend — then the **file** backend (millions of small files → inode exhaustion; since migrated to raft). If the reconciler re-issues SecretIDs, that resource type must never be used against production.
2. **Do `Policy` / `Backend` / `AuthBackendRole` MRs settle** (create once, observe, no churn) so the same YAML promotes with only `providerConfigRef` changed.
3. **Can the audit device be enabled declaratively?** (Chart default is `auditStorage.enabled: false`; production values only set a storageClass → auditing may never have been switched on, which the access model implicitly assumes.)

## Fidelity — why this is raft-on-disk, not dev mode

The first draft of this scaffold ran in **dev mode (in-memory)**. That was wrong for the question at hand: in-memory hides the WAL/snapshot/disk behaviour that is *precisely* the failure mode we are testing. So:

| Dimension | Staging | Production | Note |
|---|---|---|---|
| Storage engine | raft (`/openbao/data`) | raft | same |
| Snapshot tuning | `threshold 8192`, `interval 120`, `trailing_logs 10000` | same | copied from prod values |
| StorageClass | `longhorn` | `local-path` | this cluster's default. Longhorn is network-attached → *pessimistic* latency, i.e. errs toward showing a problem. Safe direction for a safety test; not a substitute for a final check on local disk |
| Audit device | enabled via MR | possibly off (finding) | rehearsed here first |
| Replicas | 1 | 1 | single-node raft either way |

## Safety properties

- Contains **nothing real**; no ingress, no UI, no injector, no CSI — reachable only cluster-internally.
- **Structurally isolated from production:** this cluster runs the vault provider but had *no* ProviderConfig for it. The one added here (`bao-staging`) points at `http://openbao.bao-staging.svc:8200`. Production's ProviderConfig exists only in `hetzner-k8s`.
- **Not ephemeral any more** (raft needs a disk): data lives in PVCs while it exists — see Teardown.

## Files

| File | What |
|---|---|
| `bao-staging.yaml` | ArgoCD Application → openbao chart 0.29.4, prod-mirroring values (wave 2) |
| `values.yaml` | raft on PVC + audit storage (see fidelity table) |
| `02-providerconfig.yaml` | Crossplane `ProviderConfig bao-staging` → the staging instance |
| `10-policy-atuin-ro.yaml` | the **intended production** read-only agent policy |
| `15-audit-device.yaml` | audit device MR (rehearsal of the production finding) |
| `20-auth-approle.yaml` | mounts the `approle` auth backend |
| `30-role-atuin-ro.yaml` | AppRole role with intended production TTLs (`num_uses=1`, `ttl=600`) |
| `40-secretid-EXPERIMENT.yaml` | ⚠️ the artefact under test |

## Bootstrap order (raft needs init + unseal — one time)

```bash
# 1. wait for the pod (it will be sealed)
kubectl -n bao-staging rollout status statefulset/openbao

# 2. initialise (keep this file out of git)
kubectl -n bao-staging exec openbao-0 -- bao operator init \
  -key-shares=1 -key-threshold=1 -format=json > /tmp/bao-staging-init.json
UNSEAL=$(jq -r '.unseal_keys_b64[0]' /tmp/bao-staging-init.json)
ROOT=$(jq -r '.root_token' /tmp/bao-staging-init.json)

# 3. unseal
kubectl -n bao-staging exec openbao-0 -- bao operator unseal "$UNSEAL"

# 4. give Crossplane a credential (staging only, discard afterwards)
kubectl -n crossplane-system create secret generic bao-staging-token \
  --from-literal=config="{\"token\":\"$ROOT\"}"
```

Then confirm the rehearsed resources:

```bash
kubectl -n crossplane-system get policies,audits,backends,authbackendroles
kubectl -n bao-staging exec openbao-0 -- bao audit list      # expect: file/
```

## Experiment protocol

**Phase A — control (SecretID MR absent).** Remove `40-secretid-EXPERIMENT.yaml`, let ArgoCD sync, wait ~1 min, then measure the window twice, 15 min apart:

```bash
# (a) provider-side: hits on the secret-id endpoint
kubectl -n crossplane-system logs deploy/upbound-provider-vault --since=15m | grep -c 'secret-id'

# (b) server-side: handled requests (metric prefix may be vault_ or openbao_)
kubectl -n bao-staging exec openbao-0 -- sh -c \
  'BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao read -format=prometheus sys/metrics' \
  | grep handle_request

# (c) DISK cost (the dimension in-memory hid)
kubectl -n bao-staging exec openbao-0 -- du -sm /openbao/data /openbao/audit
```

**Phase B — test (SecretID MR present).** Re-add the file, let ArgoCD sync, repeat (a)/(b)/(c) over the same 15-minute window.

**Verdict:**
- (a) flat, (b) delta ≈ background, (c) flat, MR status settled → the MR type is safe to use in production with `num_uses=1`.
- (a) climbing, (b) scaling with the reconcile interval, (c) growing, or status oscillating `Creating`/`Ready` (`kubectl -n crossplane-system get -w authbackendrolesecretid atuin-ro-secretid`) → **loop confirmed**: production keeps issuing SecretIDs out-of-band (`bao write -f auth/approle/role/<role>/secret-id`) and the MR type is banned from the production repo.

## Teardown

```bash
rm -rf devops/argocd/bao-staging                     # ArgoCD prunes app + MRs
argocd app delete bao-staging --cascade              # (or immediately)
kubectl -n crossplane-system delete providerconfig bao-staging secret bao-staging-token
# raft PVCs are NOT deleted automatically (StatefulSet volumeClaimTemplates survive):
kubectl -n bao-staging delete pvc -l app.kubernetes.io/instance=openbao
```

## Promotion path (after the experiment)

| Staging file | Production change (`hetzner-k8s`) |
|---|---|
| `10-policy-atuin-ro.yaml` | same YAML, `providerConfigRef: bao-hnatekmar-xyz` |
| `15-audit-device.yaml` | **if auditing really is off in production**, this is the fix |
| `30-role-atuin-ro.yaml` | only if the AppRole path survives; otherwise tokens out-of-band |
| — | tighten `hermes/policies/hermes-agent.yaml` from mount-wide CRUD to read-only |
| — | retire `roles/approle/hermes-agent-secretid.yaml` (issue a replacement out-of-band first) |
| — | update `hermes/README.md` secret registry with `hermes/agents/atuin/*` |

## Findings to carry over regardless

- **Audit may not be enabled in production** — verified here as an MR-shaped fix.
- **`server.image.tag: "latest"`** in production values + ArgoCD self-heal = silent upgrades of a one-way storage format. Pin it.
- **No visible raft snapshot backup.** Single-node raft on a `local-path` PVC dies with the node. A scheduled `bao operator raft snapshot save` to the NAS is the difference between restoring secrets and rebuilding every credential in the estate.
