# Forgejo (GitOps)

The forge, as an ArgoCD application. Written from the running prototype on the dev cluster — the live
objects were read back and transcribed, not retyped from memory — so this is a description of what
actually works, with the prototype's warts called out where they are.

```
devops/argocd/forgejo/
  forgejo.yaml            Application (dev): upstream chart (pinned) + manifests/ + this repo as `repo`
  values-dev.yaml         the chart's values for dev
  values-prod.yaml        the same for prod — the hostname and the registry-sized PVC are the deltas
  manifests/
    10-postgres.yaml      the database: StatefulSet + headless Service, block tier, PVC retained
    20-runner.yaml        the Actions runner: namespace (privileged), label map, PVC, Deployment + DinD
    30-sso-client.yaml    the Keycloak client, owned by the cluster that consumes its secret
  manifests-prod/         prod's DB + SSO client (same shape; the client is cluster-local by design)
bootstrap/argocd/prod/forgejo.yaml
                          the prod PLACEMENT: the prod root recurses bootstrap/argocd/prod/, so this
                          is what ArgoCD on prod applies. The dev app has no such file yet — see below
```

## What has to exist before the first sync

Nothing here is in git, on purpose — they are credentials:

| Secret | Namespace | Keys | How it is produced |
|---|---|---|---|
| `forgejo-db` | `forgejo` | `password` | generated; the same value must reach Postgres and Forgejo (the chart injects it into `app.ini`, the StatefulSet into `POSTGRES_PASSWORD`) |
| `runner-registration` | `forgejo-runner` | `token` | `kubectl -n forgejo exec deploy/forgejo -c forgejo -- forgejo forgejo-cli actions generate-runner-token --scope hnatekmarorg` |
| `forgejo-admin` | `forgejo` | `username`, `password` | the local break-glass admin; only needed on a fresh database |
| `forgejo-oidc` | `forgejo` | `attribute.client_secret` | **not created by hand** — Crossplane writes it from the `Client` in `manifests/30-sso-client.yaml` |

`forgejo-tls` is also absent and correctly so: cert-manager issues it from the ingress annotation.

The two mechanisms the estate already has for this (`SopsSecret` for what cannot come from the vault,
ESO/OpenBao for what can) are both applicable — the transcription stopped short of wiring them because
the prototype's secrets were created out of band and lifting them into a mechanism is a change that
should be made deliberately, not guessed at. Until then the app syncs only once they exist by hand.

## Values: dev vs prod

The requirement when the prototype was built was *do not wire anything permanently to the dev cluster*,
so the forge's topology lives in `values-dev.yaml` and the move to production is a values change:

1. copy `values-dev.yaml` → `values-prod.yaml`;
2. change the hostname in the three places it appears (`gitea.config.server.ROOT_URL`, the ingress host,
   the ingress TLS host) and the SSO client's URLs in `manifests/30-sso-client.yaml`;
3. point `forgejo.yaml`'s `valueFiles` at it.

**State (2026-10-10):** steps 1-3 are done — `values-prod.yaml` and `manifests-prod/` exist, and the
prod placement is `bootstrap/argocd/prod/forgejo.yaml`. Prod's remaining prerequisites are the two
hand-made credentials from the table above (`forgejo-db`, and `forgejo-admin` because that database is
fresh) plus the registry GC task noted in `values-prod.yaml`. The RUNNER is deliberately not part of
prod yet — it lands with the CI migration, not before it.

**Still absent, deliberately:** the dev app's own placement under `bootstrap/argocd/dev/`. The dev
declaration adopts a RUNNING instance — live CI — so putting it under the dev root means ArgoCD takes
ownership of objects the CI depends on. That change deserves its own review, not a side effect of this
one.

Then re-check the two things that are *deliberately* per-cluster rather than global:

* the runner's `--labels` list **and** the `config.yaml` label map in `manifests/20-runner.yaml` — the
  server matches `runs-on` against the labels recorded at registration, and `register` silently drops
  any label `config.yaml` does not define;
* `providerConfigRef` on the SSO client — the NAME is deliberately the same on both clusters
  (`sso-hnatekmar-xyz`, see the chart's keycloak-writer template); only the identity behind it differs,
  and prod's is verified live.

## The one remaining outbound dependency

`gitea.config.actions.DEFAULT_ACTIONS_URL: https://github.com`. Forgejo's workflows fetch the actions
they `uses:` from a URL the **server** sends with each task, and Forgejo's own default
(`data.forgejo.org`) does not carry `actions/checkout@v4` or `opentofu/setup-opentofu@v1`. Measured:
without this value, `setup-opentofu` fails with `repository not found`. So a migration away from GitHub
that keeps working still reaches github.com for action code. Mirroring the handful of actions needed
into this instance is the fix; it is not done here.

## Known gaps (statements, not surprises)

* **No `environment:` equivalent.** Forgejo has no per-environment secrets or approval gates, so
  `clusters-production`'s reviewer gate cannot be reproduced as it stands. The replacement is a
  short-lived credential pulled at run time (OIDC token → OpenBao, bound to `ref_protected`), which is
  worth doing on GitHub as well.
* **The runner's `/data` is statically bound NFS on dev** (`manifests/20-runner.yaml` says why not to
  carry that to prod). On this NAS export it has history: the directory the PVC landed on is shared with
  unrelated objects, which is why the volume listing looks like a NAS dump rather than a CI runner.
* **`actions/upload-artifact@v4`** is used by the `tofu-apply` composite action and has not been
  exercised on Forgejo here — the apply path needs device credentials this prototype does not have.
