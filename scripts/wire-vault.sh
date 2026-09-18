#!/usr/bin/env bash
# Wire a cluster to the vault: the vault side of ESO's kubernetes auth.
#
#   BAO_TOKEN=... ./scripts/wire-vault.sh dev
#
# The KUBERNETES side (the ClusterSecretStore, the ESO service account) is declarative and lives in
# cluster-base. This is the other half, which is not a Kubernetes object and therefore has no home in
# GitOps — the vault's own configuration for talking back to this cluster.
#
# WHY IT IS A SCRIPT AND NOT TERRAFORM: it spans two systems (the vault and the cluster), and the vault
# side is a small idempotent upsert of the kind bao/kubectl do naturally. The interesting part is not
# the mechanism, it is the per-cluster value below.
#
# The token is read from BAO_TOKEN and never passed as an argument, so it cannot land in argv or the
# process list — same rule as the unseal key.
set -euo pipefail

CLUSTER="${1:?usage: BAO_TOKEN=... wire-vault.sh <cluster>   e.g. wire-vault.sh dev}"
ROOT="terraform/clusters/${CLUSTER}"
[ -d "$ROOT" ] || { echo "no such cluster root: $ROOT" >&2; exit 1; }

: "${BAO_TOKEN:?set BAO_TOKEN (the vault token); it is read from the environment on purpose}"
BAO_ADDR="${BAO_ADDR:-https://bao.srv.hnatekmar.dev}"
ESO_NS="${ESO_NS:-external-secrets}"
ESO_SA="${ESO_SA:-external-secrets}"
ROLE="${ROLE:-local-${CLUSTER}}"

# ONE MOUNT PER CLUSTER, and this is forced by the vault, not a style choice:
# `auth/kubernetes/config` holds a single kubernetes_host + kubernetes_ca_cert + token_reviewer_jwt.
# A second cluster cannot share the mount because its CA and its reviewer token differ. Hence
# auth/kubernetes-<cluster>/, and cluster-base's ClusterSecretStore must name the same path.
MOUNT="kubernetes-${CLUSTER}"

say() { printf '\n== %s\n' "$*"; }

say "cluster kubeconfig (for the CA and to mint a reviewer token)"
KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
( cd "$ROOT" && tofu output -raw kubeconfig ) > "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

# The CA is a public certificate; it goes to a world-readable temp file on purpose, and the vault needs
# it to validate this cluster's API server. It CHANGES ON EVERY REBUILD, which is the whole reason this
# script exists: a stale CA here produces auth failures that look like anything but a stale CA.
CA_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE" "$CA_FILE"' EXIT
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "$CA_FILE"
API_HOST="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo "  api: $API_HOST"

say "reviewer service account + token (this is what lets the vault call TokenReview)"
kubectl -n kube-system get serviceaccount vault-reviewer >/dev/null 2>&1 || \
  kubectl -n kube-system create serviceaccount vault-reviewer >/dev/null
kubectl -n kube-system get secret vault-reviewer-token >/dev/null 2>&1 || cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: vault-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-reviewer
type: kubernetes.io/service-account-token
YAML
kubectl create clusterrolebinding vault-reviewer:auth-delegator \
  --clusterrole=system:auth-delegator --serviceaccount=kube-system:vault-reviewer \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# wait for the token controller to populate it
for _ in $(seq 1 20); do
  JWT="$(kubectl -n kube-system get secret vault-reviewer-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [ -n "$JWT" ] && break
  sleep 2
done
[ -n "${JWT:-}" ] || { echo "reviewer token never populated" >&2; exit 1; }
echo "  reviewer token: ${#JWT} bytes (never printed)"

say "vault: auth mount $MOUNT"
BAO_ADDR="$BAO_ADDR" bao auth list 2>/dev/null | grep -q "^${MOUNT}/" || \
  BAO_ADDR="$BAO_ADDR" bao auth enable -path="$MOUNT" kubernetes >/dev/null 2>&1 || true

say "vault: point $MOUNT at this cluster"
# The JWT goes in via a temp file, not argv: a token in argv is visible in the process list.
JWT_FILE="$(mktemp)"; chmod 600 "$JWT_FILE"
printf '%s' "$JWT" > "$JWT_FILE"
trap 'rm -f "$KUBECONFIG_FILE" "$CA_FILE" "$JWT_FILE"' EXIT
BAO_ADDR="$BAO_ADDR" bao write "auth/${MOUNT}/config" \
  kubernetes_host="$API_HOST" \
  kubernetes_ca_cert=@"$CA_FILE" \
  token_reviewer_jwt=@"$JWT_FILE" \
  disable_iss_validation=true >/dev/null
echo "  configured (CA from the live cluster, reviewer token from the live cluster)"

say "vault: role $ROLE bound to ESO in $ESO_NS"
BAO_ADDR="$BAO_ADDR" bao write "auth/${MOUNT}/role/${ROLE}" \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$ESO_NS" \
  token_policies="local-${CLUSTER}-read" \
  token_ttl=1h token_max_ttl=4h >/dev/null
echo "  role $ROLE -> ${ESO_NS}/${ESO_SA}"

say "vault: read policy"
BAO_ADDR="$BAO_ADDR" bao policy write "local-${CLUSTER}-read" - >/dev/null <<POLICY
path "secret/data/${CLUSTER}/*"    { capabilities = ["read"] }
path "secret/metadata/${CLUSTER}/*" { capabilities = ["read", "list"] }
POLICY
echo "  local-${CLUSTER}-read -> secret/${CLUSTER}/*"

cat <<EOF

Vault is wired to ${CLUSTER}.

  mount: auth/${MOUNT}          (one per cluster: CA and reviewer token differ per cluster)
  role:  ${ROLE}               bound to ${ESO_NS}/${ESO_SA}
  reads: secret/${CLUSTER}/*

cluster-base's ClusterSecretStore must name the same mount path. Re-run this after every rebuild —
the CA changes, and a stale CA here fails in a way that looks unrelated.
EOF
