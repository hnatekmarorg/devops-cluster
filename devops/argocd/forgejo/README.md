# Forgejo (GitOps)

The forge, as an ArgoCD application. Written from the running prototype on the dev cluster — the live
objects were read back and transcribed, not retyped from memory — so this is a description of what
actually works, with the prototype's warts called out where they are.

```
devops/argocd/forgejo/
  forgejo.yaml            Application: upstream chart (pinned) + manifests/ + this repo as `repo`
  values-dev.yaml         the chart's values for dev  (prod = a copy with four lines changed)
  manifests/
    10-postgres.yaml      the database: StatefulSet + headless Service, block tier, PVC retained
    20-runner.yaml        the Actions runner: namespace (privileged), label map, PVC, Deployment + DinD
    30-sso-client.yaml    the Keycloak client, owned by the cluster that consumes its secret
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

Then re-check the two things that are *deliberately* per-cluster rather than global:

* the runner's `--labels` list **and** the `config.yaml` label map in `manifests/20-runner.yaml` — the
  server matches `runs-on` against the labels recorded at registration, and `register` silently drops
  any label `config.yaml` does not define;
* `providerConfigRef` on the SSO client — that cluster's own Keycloak writer.

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
