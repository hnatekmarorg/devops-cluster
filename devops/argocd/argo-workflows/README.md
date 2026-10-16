# argo-workflows (dev)

Upstream Argo Workflows on the dev cluster — chart `argo-workflows` 1.0.14 (**app v4.0.5**),
deployed by ArgoCD from `bootstrap/argocd/dev/argo-workflows.yaml` (the root Application
recurses over `bootstrap/argocd/dev/`). Control plane in `argo-workflows`, workflow pods in
`workflows`, archive in the namespace-local Postgres, artifacts in the NAS MinIO.

## Pieces

| Piece | Where | Owner |
|---|---|---|
| chart (controller/server/executor, ingress, configmap) | this directory (`values-dev.yaml`) | argoproj.github.io/argo-helm, pinned 1.0.14 |
| Postgres (StatefulSet + Service `postgres`) | `manifests/10-postgres.yaml` | this repo |
| Keycloak client `argo-workflows-dev` + its default scopes | `manifests/20-sso-client.yaml` | this repo (Crossplane) |
| SSO-RBAC service accounts (`k8s-dev-admin` -> admin, `k8s-dev-viewer` -> viewer) | `manifests/30-sso-rbac.yaml` | this repo |
| namespace `workflows` | `manifests/00-workflows-namespace.yaml` | this repo |

## Prerequisites (out-of-band — credentials are not in git)

1. **Secret `postgres-db-credentials`** in `argo-workflows` (keys `username`, `password`).
   Without it the Postgres pod sits in CreateContainerConfigError; the chart's controller
   crashloops on the missing secret. (Same convention as forgejo's `forgejo-db`.)
2. (Deferred) **Secret `s3-artifacts-credentials`** (keys `accesskey`, `secretkey`) — a MinIO
   user scoped to bucket `dev-argo-workflows-cf6a0c3` (reference naming scheme:
   `<cluster>-argo-workflows-<sha256(cluster-argo-workflows)[0:7]>`) on the NAS
   (`minio.srv.hnatekmar.dev:9000`, region `europe`, plain HTTP). Not wired yet — see
   `values-dev.yaml` for the exact block to add.

## Two controllers, one cluster (bench parked)

The `argo-bench` harness runs its own (fork) controller on this cluster, and Argo controllers
are cluster-wide by default — two of them would reconcile the same Workflows. **The bench is
parked while this deployment runs** (its `workflow-controller` and `argo-server` are scaled to
0; Postgres/MariaDB/bench-bins stay up so state is one scale-up away):

```bash
# resume the bench (stop this deployment first, or scope the bench at the same time):
kubectl -n argo-bench scale deploy/workflow-controller deploy/argo-server --replicas=1
```

This deployment's controller is scoped to `workflows`
(`--namespaced --managed-namespace=workflows`, the supported single-namespace mode), so it
leaves everything in `argo-bench` untouched. The argo-server stays cluster-wide (read/display
is harmless; it creates no pods).

## SSO

- Client `argo-workflows-dev` (CONFIDENTIAL) with default scopes incl. `microprofile-jwt` —
  the scope that carries realm roles into the `groups` claim.
- `sso.rbac.enabled: true` requires matching service-account rules or it denies everyone;
  `manifests/30-sso-rbac.yaml` provides them, mirroring the cluster-access groups.
- Anyone outside `k8s-dev-*` is denied (the group filter is in `values-dev.yaml`).

## Verify

```bash
export KUBECONFIG=/root/.kube/dev-talos.yaml
kubectl -n argocd get application argo-workflows
kubectl -n argo-workflows get deploy,sts,svc,sa
kubectl -n workflows get role,rolebinding
# submit a workflow through the server (server-side; kubectl create goes straight to the API
# server and skips the offload path anyway):
kubectl -n argo-workflows port-forward svc/argo-workflows-server 2746:2746 &
# then, from a host that can reach it: the UI at https://workflows.dev-k8s.srv.hnatekmar.dev
```

## Follow-ups (not in this change)

- **Wire the artifact repository** (NAS MinIO bucket `dev-argo-workflows-cf6a0c3` + a scoped
  user; block ready-to-paste in `values-dev.yaml`) and flip `archiveLogs` back to true.
- `readTimeout` / `writeTimeout` / `idleTimeout` for massive-scale submissions are top-level
  ConfigMap keys the stock chart does not render — out-of-band patch or a small chart PR.
- A ServiceMonitor for the controller metrics (the cluster-base Grafana dashboard exists).
- A dedicated NetworkPolicy set if the cluster gets multi-tenant.
