#!/usr/bin/env bash
# Regenerate a cluster's OIDC kubeconfig into its directory.
#
#   ./scripts/kubeconfig.sh dev
#
# Run this AFTER EVERY REBUILD. The kubeconfig carries the cluster's CA, and a rebuilt cluster has a
# new one, so a stale committed file fails with `x509: certificate signed by unknown authority` —
# an error that looks like anything but a stale file.
#
# The kubeconfig this writes contains NO credential: endpoint, public CA, and a kubelogin exec block.
# The identity lives in Keycloak, which is why committing it is safe and why it is worth having in git
# rather than handed around.
set -euo pipefail

CLUSTER="${1:?usage: kubeconfig.sh <cluster>   e.g. kubeconfig.sh dev}"
ROOT="terraform/clusters/${CLUSTER}"
[ -d "$ROOT" ] || { echo "no such cluster root: $ROOT" >&2; exit 1; }

OUT="${ROOT}/kubeconfig.yaml"
(cd "$ROOT" && tofu output -raw oidc_kubeconfig) > "$OUT"

# Enforce the invariant rather than trusting it. If a credential ever appears here — because a future
# change reintroduced client-certificate auth, say — the file must not be committed.
if grep -qE 'client-certificate-data|client-key-data|^ *token:|password:' "$OUT"; then
  rm -f "$OUT"
  echo "REFUSING to write $OUT: it contains credential material, so it is not safe to commit." >&2
  exit 1
fi

echo "wrote $OUT (no credential — safe to commit)"
command -v kubelogin >/dev/null 2>&1 || \
  echo "note: kubelogin is not on PATH; that kubeconfig needs it to authenticate." >&2
