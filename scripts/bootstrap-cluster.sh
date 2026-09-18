#!/usr/bin/env bash
# Bootstrap a freshly provisioned cluster: install ArgoCD, hand it the repository.
#
#   ./scripts/bootstrap-cluster.sh dev
#
# This is the IMPERATIVE side of a deliberate boundary:
#   below — the cluster exists and ArgoCD is running   → bootstrap, one-time, idempotent
#   above — every application, add-on and policy       → declarative, via ArgoCD
#
# So this script installs exactly two things and stops. Anything more would be duplicating what ArgoCD
# is about to do, and would drift from it.
#
# Safe to re-run: helm upgrade --install and kubectl apply are both upserts.
set -euo pipefail

CLUSTER="${1:?usage: bootstrap-cluster.sh <cluster>   e.g. bootstrap-cluster.sh dev}"
ROOT="terraform/clusters/${CLUSTER}"
[ -d "$ROOT" ] || { echo "no such cluster root: $ROOT" >&2; exit 1; }

ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-}"   # empty = chart default; pin when it matters

say() { printf '\n== %s\n' "$*"; }

# The admin kubeconfig, not the OIDC one: this runs unattended and cannot open a browser for kubelogin.
# It is a credential, so it lives in a 0600 temp file and is removed on exit.
say "cluster kubeconfig"
KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
( cd "$ROOT" && tofu output -raw kubeconfig ) > "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

say "waiting for the API server"
for _ in $(seq 1 30); do
  kubectl get --raw /healthz >/dev/null 2>&1 && break
  sleep 5
done
kubectl get --raw /healthz >/dev/null 2>&1 || { echo "API server never came up" >&2; exit 1; }
kubectl get nodes --no-headers | sed 's/^/  /'

say "installing ArgoCD into $ARGOCD_NS"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm_args=(upgrade --install argocd argo/argo-cd --namespace "$ARGOCD_NS" --create-namespace
            --wait --timeout 10m)
[ -n "$ARGOCD_CHART_VERSION" ] && helm_args+=(--version "$ARGOCD_CHART_VERSION")
helm "${helm_args[@]}" | tail -5 | sed 's/^/  /'

say "waiting for ArgoCD to serve"
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=300s | sed 's/^/  /'

say "handing ArgoCD this cluster's directory"
# The root Application, recursing over bootstrap/argocd/<cluster>. Everything under it is an ArgoCD
# Application — cluster-base (which needs the cluster's CLASS), and later any add-ons.
sed "s|path: bootstrap/argocd$|path: bootstrap/argocd/${CLUSTER}|" bootstrap/init.yaml \
  | kubectl apply -f - | sed 's/^/  /'

say "what ArgoCD will now converge"
kubectl -n "$ARGOCD_NS" get applications -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null | sed 's/^/  /' || true

cat <<EOF

ArgoCD is up and pointed at bootstrap/argocd/${CLUSTER}.

  port-forward for the UI:  kubectl -n ${ARGOCD_NS} port-forward svc/argocd-server 8080:443
  initial admin password:   kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret \\
                              -o jsonpath='{.data.password}' | base64 -d

Next, if this cluster is to consume secrets from the vault:
  ./scripts/wire-vault.sh ${CLUSTER}
EOF
