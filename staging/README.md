# staging/ — disposable rehearsal environments

**Deliberately outside the GitOps-managed trees** (`devops/argocd/`, `bootstrap/argocd/`). Anything inside those paths is applied to a *real* cluster by ArgoCD; rehearsal artifacts must never be. Nothing here is deployed automatically — you run it against a disposable cluster, and you tear it down.

## `staging/bao/` — OpenBao + Crossplane auth/policy rehearsal

Purpose: answer questions about the live identity stack (`bao.hnatekmar.xyz`, managed from `hetzner-k8s`) **without touching it**, on a throwaway Kind cluster.

### Results (measured 2026-09-14 — Kind node v1.32.2, Crossplane 1.20.0, provider-vault v3.0.2, OpenBao chart 0.29.4)

| Question | Answer |
|---|---|
| Do `Policy` / `Backend` / `AuthBackendRole` MRs settle? | ✅ yes — `Ready/Synced`, idle in steady state |
| Does a declarative `AuthBackendRoleSecretID` loop? | ⚠️ **yes, causally proven** |
| Can the audit device be enabled as an MR? | ❌ impossible against OpenBao |

Request counts per window, taken from the audit log (which doubles as a request counter):

| Window | SecretID MR | Requests / 150 s |
|---|---|---|
| control | absent | **0** |
| test | present | **176** (audit lines 9 → 231) |
| after delete | removed | **0** (flat for 90 s) |

### The two findings that block the obvious implementations

1. **Audit cannot be enabled via the API in OpenBao.** The server answers *"cannot enable audit device via API; use declarative, config-based audit device management instead"*. It must be declared in the server config — `audit "file" "<path>" { options { file_path = … } }` — which the chart passes through `server.standalone.config`.
   **Consequence: production auditing is OFF** (`hetzner-k8s` values only set `auditStorage.storageClass`, and the API path is blocked by design — it cannot have been enabled another way). The docs also warn that *audit failure blocks request handling*, so run **at least two devices**, with rotation and a volume alert.
2. **`AuthBackendRoleSecretID` does not work against OpenBao.** The provider's call `PUT /v1/auth/approle/role/<role>/secret-id` returns `404 no handler for route`, while the identical route works from the CLI (`bao write -f …/secret-id` returned a secret_id; the role itself carries our intended `num_uses=1` / `ttl=10m`). Crossplane retries forever, so the resource's only effect is traffic. Combined with the production MR's `secretIdNumUses: 0`, this is the mechanism behind the earlier "AppRole overloaded OpenBao" incident.
   **Verdict: ban that resource type in the production repo; issue SecretIDs out-of-band, single-use.**

### Layout

| Path | What |
|---|---|
| `rehearse.sh` | end-to-end: verify context → install Crossplane + provider-vault → install OpenBao → bootstrap (init/unseal/credential) → apply MRs → print the A/B recipe |
| `values.yaml` | OpenBao values: raft on `standard` (Kind's `rancher.io/local-path` = hostPath, matching production's `local-path`), config-based audit device, audit storage enabled |
| `manifests/` | the Crossplane MRs that promote verbatim (only `providerConfigRef` changes) |
| `manifests/99-secretid-EXPERIMENT-do-not-promote.yaml` | the negative experiment — kept so the result stays reproducible, never promoted |

### Running it

```bash
kind create cluster --name bao-staging
./staging/bao/rehearse.sh        # refuses to run against anything but the bao-staging kind context

# teardown
kind delete cluster --name bao-staging
kubectl delete pvc --all -n bao-staging        # volumeClaimTemplates survive chart deletion
```

Bootstrap lesson learned the hard way: **persist the unseal key**, not just the root token (the script writes both to `${KEYS:-/tmp/bao-staging-keys}/`, mode 600).

### Production change list (evidence-backed, for the `hetzner-k8s` PR)

1. **Enable auditing properly** — `audit` stanza in `argocd/openbao/values.yaml` (`server.standalone.config`), plus a second device and rotation, plus an alert on the audit volume (fail-closed semantics).
2. **Retire `crossplane/config/bao/bao-hnatekmar-xyz/roles/approle/hermes-agent-secretid.yaml`** — after issuing a replacement SecretID out-of-band once.
3. **Add `policies/atuin-ro.yaml`** — read-only, scoped to `hermes/data/agents/atuin/*` (validated here).
4. **Tighten `hermes/policies/hermes-agent.yaml`** — mount-wide CRUD → read-only.
5. **Pin `server.image.tag`** — `"latest"` + ArgoCD self-heal = silent upgrades of a one-way storage format.
6. **Raft snapshot backup** — still absent; single-node raft on `local-path` dies with the node.
