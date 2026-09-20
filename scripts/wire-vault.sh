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

# Tools before anything else. The bao CLI is the obvious one, and it was missing from the CI runner
# image — found only when the step failed, because nothing checked. Same shape as bootstrap-cluster.sh.
for _tool in bao kubectl tofu; do
  command -v "$_tool" >/dev/null 2>&1 || {
    echo "wire-vault.sh: $_tool is not on PATH — install it first (the CI job does)" >&2
    exit 69
  }
done

CLUSTER="${1:?usage: BAO_TOKEN=... wire-vault.sh <cluster>   e.g. wire-vault.sh dev}"
ROOT="terraform/clusters/${CLUSTER}"
# The cluster root is only needed to derive a kubeconfig when the caller has none. With KUBECONFIG set,
# this script is runnable from anywhere — including the runner, which has no repository checkout at all
# (CI jobs run in an ephemeral container).
if [ -z "${KUBECONFIG:-}" ] && [ ! -d "$ROOT" ]; then
  echo "no cluster root $ROOT and no KUBECONFIG: pass one, or run from the repository root" >&2
  exit 1
fi

# The token: BAO_TOKEN wins, otherwise /etc/bao_token — which is where the runner keeps it, so CI does
# not need the secret in its environment. Never as an argument: a token in argv is visible in the
# process list.
# EXPORTED. Without it the value is a shell variable, the bao CLI never sees it, and every call fails
# with a 403 that looks exactly like an insufficient policy.
if [ -z "${BAO_TOKEN:-}" ] && [ -r /etc/bao_token ]; then
  BAO_TOKEN="$(tr -d '\n' < /etc/bao_token)"
fi
if [ -z "${BAO_TOKEN:-}" ]; then
  echo "no vault token: set BAO_TOKEN or place one in /etc/bao_token" >&2
  exit 1
fi
export BAO_TOKEN
export BAO_ADDR="${BAO_ADDR:-https://bao.srv.hnatekmar.dev}"
: "${BAO_TOKEN:?no vault token: set BAO_TOKEN, or place the token in /etc/bao_token (mode 0600)}"

# Flag a token file others can read rather than quietly using it.
if [ -f /etc/bao_token ]; then
  _mode="$(stat -c '%a' /etc/bao_token 2>/dev/null || echo '?')"
  [ "$_mode" = "600" ] || echo "warning: /etc/bao_token is mode $_mode; 0600 recommended" >&2
fi
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
# Honour a kubeconfig the caller supplies. In CI the state is initialised and the caller may already
# have one; the runner has no repository checkout at all, so the tofu fallback cannot work there.
if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
  cp "$KUBECONFIG" "$KUBECONFIG_FILE"
  echo "  using KUBECONFIG from the environment"
else
  ( cd "$ROOT" && tofu output -raw kubeconfig ) > "$KUBECONFIG_FILE"
fi
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
# The listing is indented, so anchor loosely — "^\${MOUNT}/" never matches and the enable would run
# every time. And do NOT swallow the failure: a 403 on a mount that does not exist looks identical to
# a token without permission, which cost two rounds of policy debugging.
if ! BAO_ADDR="$BAO_ADDR" bao auth list 2>/dev/null | grep -qE "^[[:space:]]*${MOUNT}/"; then
  if ! BAO_ADDR="$BAO_ADDR" bao auth enable -path="$MOUNT" kubernetes; then
    echo "failed to enable auth/${MOUNT} — see the error above" >&2
    exit 1
  fi
else
  echo "  auth/${MOUNT} already enabled"
fi

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
# TWO prefixes, and the split is a decision rather than tidiness:
#   * `common/*`    — values that are identical on every cluster (the Cloudflare cert token, the NAS
#                     API key). One copy, so there is no per-cluster copy to forget: measured, dev's
#                     cloudflare path was seeded by hand once and prod's never was, which left prod's
#                     cert-manager on `SecretSyncedError: Secret does not exist` behind a store that
#                     reported Valid — the store check exercises the AUTH, not the data path.
#   * `<cluster>/*` — genuinely per-cluster values only.
# Read-only either way. Writing the data is scripts/seed-vault.sh, which needs its own token.
BAO_ADDR="$BAO_ADDR" bao policy write "local-${CLUSTER}-read" - >/dev/null <<POLICY
path "secret/data/${CLUSTER}/*"    { capabilities = ["read"] }
path "secret/metadata/${CLUSTER}/*" { capabilities = ["read", "list"] }
path "secret/data/common/*"    { capabilities = ["read"] }
path "secret/metadata/common/*" { capabilities = ["read", "list"] }
POLICY
echo "  local-${CLUSTER}-read -> secret/${CLUSTER}/* + secret/common/*"

cat <<EOF

Vault is wired to ${CLUSTER}.

  mount: auth/${MOUNT}          (one per cluster: CA and reviewer token differ per cluster)
  role:  ${ROLE}               bound to ${ESO_NS}/${ESO_SA}
  reads: secret/${CLUSTER}/* + secret/common/*

NOTHING IS SEEDED HERE. This script wires auth and the policy; the DATA is written separately
(scripts/seed-vault.sh, whose `check` mode verifies the paths a cluster actually needs). A rebuild
that skips seeding comes up with a store that validates and ExternalSecrets that fail on
'Secret does not exist' — the failure this estate already paid for once.

cluster-base's ClusterSecretStore must name the same mount path. Re-run this after every rebuild —
the CA changes, and a stale CA here fails in a way that looks unrelated.
EOF
