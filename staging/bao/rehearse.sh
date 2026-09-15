#!/usr/bin/env bash
# Rehearse the OpenBao + Crossplane auth/policy work on a DISPOSABLE Kind cluster.
# Refuses to run against anything that is not the bao-staging kind context.
set -euo pipefail

CTX="kind-bao-staging"; NS="bao-staging"; XNS="crossplane-system"
KEYS="${KEYS:-/tmp/bao-staging-keys}"
HERE="$(cd "$(dirname "$0")" && pwd)"

current="$(kubectl config current-context 2>/dev/null || true)"
if [ "$current" != "$CTX" ]; then
  echo "refusing: current context is '$current', expected '$CTX'" >&2
  echo "run: kind create cluster --name bao-staging   (then re-run)" >&2
  exit 1
fi
case "$CTX" in *kind*) ;; *) echo "refusing: $CTX is not a kind context" >&2; exit 1;; esac

echo "== 1. Crossplane + vault provider"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane --version 1.20.0 -n "$XNS" --create-namespace --kube-context "$CTX" --wait
kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: { name: upbound-provider-vault }
spec: { package: xpkg.upbound.io/upbound/provider-vault:v3.0.2 }
EOF
echo "   waiting for provider CRDs..."; until kubectl get crd policies.vault.vault.upbound.io >/dev/null 2>&1; do sleep 10; done

echo "== 2. OpenBao (raft on local-path, config-based audit)"
helm upgrade --install openbao openbao/openbao --version 0.29.4 -n "$NS" --create-namespace --kube-context "$CTX" -f "$HERE/values.yaml" --wait

echo "== 3. bootstrap (init -> unseal -> provider credential)"
mkdir -p "$KEYS"; chmod 700 "$KEYS"
until kubectl -n "$NS" get pod openbao-0 --no-headers 2>/dev/null | grep -q Running; do sleep 5; done
kubectl -n "$NS" exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 bao operator init   -key-shares=1 -key-threshold=1 -format=json > "$KEYS/init.json"; chmod 600 "$KEYS/init.json"
jq -r .unseal_keys_b64[0] "$KEYS/init.json" > "$KEYS/unseal-key.txt"
jq -r .root_token       "$KEYS/init.json" > "$KEYS/root-token.txt"; chmod 600 "$KEYS"/*.txt
kubectl -n "$NS" exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 bao operator unseal "$(cat "$KEYS/unseal-key.txt")"
kubectl -n "$XNS" create secret generic bao-staging-token \
  --from-literal=config="{\"token\":\"$(cat "$KEYS/root-token.txt")\"}" --dry-run=client -o yaml | kubectl apply -f -

echo "== 4. Crossplane resources under test"
kubectl apply -f "$HERE/manifests/02-providerconfig.yaml" -f "$HERE/manifests/10-policy-atuin-ro.yaml" \
                -f "$HERE/manifests/20-auth-approle.yaml" -f "$HERE/manifests/30-role-atuin-ro.yaml"
kubectl -n "$XNS" wait --for=condition=Ready policies.vault.vault.upbound.io/atuin-ro --timeout=120s
kubectl -n "$NS" exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$(cat "$KEYS/root-token.txt")" bao audit list

cat <<'EOF'

== 5. the A/B experiment (SecretID loop)
  # control: count requests with the MR absent
  kubectl -n bao-staging exec openbao-0 -- wc -l /openbao/audit/audit.log     # t0
  sleep 150; kubectl -n bao-staging exec openbao-0 -- wc -l /openbao/audit/audit.log   # t1  -> delta ~0

  # test: apply the negative experiment and repeat
  kubectl apply -f manifests/99-secretid-EXPERIMENT-do-not-promote.yaml
  kubectl -n bao-staging exec openbao-0 -- wc -l /openbao/audit/audit.log     # t0
  sleep 150; kubectl -n bao-staging exec openbao-0 -- wc -l /openbao/audit/audit.log   # t1  -> +176 measured

  # stop it again
  kubectl -n crossplane-system delete authbackendrolesecretids.approle.vault.upbound.io atuin-ro-secretid
EOF
