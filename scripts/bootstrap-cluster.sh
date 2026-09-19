#!/usr/bin/env bash
# Bootstrap a freshly provisioned cluster: install ArgoCD, hand it the repository.
#
#   ./scripts/bootstrap-cluster.sh dev
#
# This is the IMPERATIVE side of a deliberate boundary:
#   below — the cluster exists and ArgoCD is running   → bootstrap, one-time, idempotent
#   above — every application, add-on and policy       → declarative, via ArgoCD
#
# Anything installed here is installed because ArgoCD CANNOT install it: either nothing can be scheduled
# yet, or the object ArgoCD is about to apply refers to a kind that does not exist. Each step below says
# which of those it is. That distinction is the whole reason the order matters, and getting it wrong is
# not a slow start — it is a deadlock (see the CCM, which is now first).
#
# Safe to re-run: helm upgrade --install, kubectl apply and the CRD apply are all upserts.
set -euo pipefail

CLUSTER="${1:?usage: bootstrap-cluster.sh <cluster>   e.g. bootstrap-cluster.sh dev}"
ROOT="terraform/clusters/${CLUSTER}"
[ -d "$ROOT" ] || { echo "no such cluster root: $ROOT" >&2; exit 1; }

ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-}"   # empty = chart default; pin when it matters

# These MUST track the pins in charts/cluster-base/templates/{eso,karpenter}/*.yaml. They only install
# CRDs here — ArgoCD installs the operators themselves, and would replace a mismatched CRD set.
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.10.0}"
KARPENTER_CHART_VERSION="${KARPENTER_CHART_VERSION:-0.4.9}"

CCM_CHART_VERSION="${CCM_CHART_VERSION:-0.2.0}"

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

# CI supplies the Proxmox credentials as env; a local run can keep them in /etc/proxmox-creds.env.
if [ -z "${PROXMOX_VE_API_TOKEN:-}" ] && [ -r /etc/proxmox-creds.env ]; then
  set -a; . /etc/proxmox-creds.env; set +a
fi

# ---------------------------------------------------------------------------------------------
# 1. THE CCM FIRST. Not a preference — without it nothing can be scheduled at all.
#
# Every kubelet on this cluster runs with cloud-provider=external, so it taints itself
# node.cloudprovider.kubernetes.io/uninitialized and waits. Only the CCM clears that taint. The CCM is a
# Deployment that carries tolerations for exactly that taint, which is why it can run while ArgoCD
# cannot.
#
# MEASURED, both ways, on this script:
#   ArgoCD first   its pods sit Pending and the helm --wait runs to its 10m timeout — helm waits for
#                  pods the scheduler will never place
#   CCM first      everything else schedules normally
#
# The CCM finds a VM BY NODE NAME, and the node name must be a prefix of the Proxmox VM name (see the
# factory module). The factory's --hostname-override is what makes that true for static nodes.
# ---------------------------------------------------------------------------------------------
say "installing the Proxmox CCM"
if [ -n "${PROXMOX_VE_ENDPOINT:-}" ] && [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
  ccm_cfg="$(mktemp)"; chmod 600 "$ccm_cfg"
  trap 'rm -f "$KUBECONFIG_FILE" "$ccm_cfg"' EXIT
  cat > "$ccm_cfg" <<CCMEOF
clusters:
  - url: ${PROXMOX_VE_ENDPOINT}
    insecure: ${PROXMOX_VE_INSECURE:-true}
    token_id: ${PROXMOX_VE_API_TOKEN%%=*}
    token_secret: ${PROXMOX_VE_API_TOKEN#*=}
    region: ${PROXMOX_NODE:-balteus}
CCMEOF

  # The CCM's own config.
  kubectl -n kube-system create secret generic proxmox-ccm-config \
    --from-file=config.yaml="$ccm_cfg" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # AND the same credential under the name Karpenter's chart expects. Nothing else creates it, and
  # without it BOTH the CCM and Karpenter sit in ContainerCreating on
  #   MountVolume.SetUp failed for volume "cloud-config" : secret "karpenter-provider-proxmox" not found
  # The chart's values name it `credentialsSecret`, and the CCM is documented to reuse the provider's
  # credential, so one secret serves both.
  kubectl -n kube-system create secret generic karpenter-provider-proxmox \
    --from-file=config.yaml="$ccm_cfg" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  helm upgrade --install proxmox-ccm \
    oci://ghcr.io/sergelogvinov/charts/proxmox-cloud-controller-manager \
    --version "$CCM_CHART_VERSION" --namespace kube-system \
    --set existingConfigSecret=proxmox-ccm-config \
    --set existingConfigSecretKey=config.yaml \
    --set 'enabledControllers[0]=cloud-node' \
    --set 'enabledControllers[1]=cloud-node-lifecycle' \
    --wait --timeout 5m | tail -3 | sed 's/^/  /'

  say "waiting for the CCM to clear the uninitialized taint"
  # Waiting here rather than assuming: the next step installs workloads that need a schedulable node, and
  # a taint that never clears looks exactly like a broken ArgoCD.
  for _ in $(seq 1 40); do
    taints="$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.taints[*].key}{" "}{end}')"
    case "$taints" in
      *uninitialized*) sleep 10 ;;
      *) echo "  taints now: ${taints:-<none>}"; break ;;
    esac
  done
  kubectl get nodes -o custom-columns='NAME:.metadata.name,PROVIDERID:.spec.providerID' --no-headers 2>/dev/null | sed 's/^/  /' || true
else
  echo "  SKIPPED: PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN unset — without the CCM nothing schedules." >&2
fi

# ---------------------------------------------------------------------------------------------
# 2. THE CRDs cluster-base APPLIES. A bootstrap circularity, not a version problem:
#
# cluster-base's own directory declares ClusterSecretStore, ExternalSecret, NodePool and
# ProxmoxNodeClass — whose CRDs are installed by the ESO and Karpenter Applications that cluster-base
# ITSELF creates. ArgoCD validates every resource before applying any of them, so the first sync fails:
#
#   failed to discover server resources for group version external-secrets.io/v1
#   failed to discover server resources for group version karpenter.sh/v1
#   ... (retried 5 times)
#
# and once the retries are exhausted it stops retrying (auto-sync only retries a given revision while the
# limit lasts), which is why the cluster then looks idle rather than broken.
#
# The CRDs must come from the SAME chart versions the repo pins, or ArgoCD replaces them on first sync.
# Only the CRDs are installed here, and server-side: ESO's larger CRDs exceed the 262144-byte
# last-applied-configuration annotation that client-side apply writes.
# ---------------------------------------------------------------------------------------------
install_crds() {
  local label="$1" ref="$2" version="$3" ns="$4"
  local all; all="$(mktemp)"
  helm template "$label" "$ref" --version "$version" --include-crds --namespace "$ns" > "$all" 2>/dev/null || {
    echo "  could not render $ref — CRDs not installed" >&2; rm -f "$all"; return 0; }
  local only; only="$(mktemp)"
  python3 - "$all" > "$only" <<'PY'
import re, sys
docs = open(sys.argv[1]).read().split('\n---\n')
crds = [d for d in docs if re.search(r'^kind: CustomResourceDefinition', d, re.M)]
sys.stdout.write('\n---\n'.join(crds))
PY
  local n; n="$(grep -c '^kind: CustomResourceDefinition' "$only" || true)"
  echo "  $label: $n CRDs"
  kubectl apply --server-side --force-conflicts -f "$only" >/dev/null
  rm -f "$all" "$only"
}

say "installing the CRDs cluster-base's resources need"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null 2>&1 || true
install_crds eso-crds "external-secrets/external-secrets" "$ESO_CHART_VERSION" external-secrets
install_crds kar-crds "oci://ghcr.io/sergelogvinov/charts/karpenter-provider-proxmox" "$KARPENTER_CHART_VERSION" kube-system
for g in external-secrets.io/v1 karpenter.sh/v1; do
  kubectl get --raw "/apis/$g" >/dev/null 2>&1 && echo "  $g: resolvable" || echo "  $g: STILL MISSING" >&2
done

# ---------------------------------------------------------------------------------------------
# 3. ArgoCD. Now that nodes are schedulable it can actually come up.
# ---------------------------------------------------------------------------------------------
say "installing ArgoCD into $ARGOCD_NS"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm_args=(upgrade --install argocd argo/argo-cd --namespace "$ARGOCD_NS" --create-namespace
            --wait --timeout 10m)
[ -n "$ARGOCD_CHART_VERSION" ] && helm_args+=(--version "$ARGOCD_CHART_VERSION")
helm "${helm_args[@]}" | tail -5 | sed 's/^/  /'

say "waiting for ArgoCD to serve"
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=300s | sed 's/^/  /'

# ---------------------------------------------------------------------------------------------
# 4. THE KARPENTER JOIN SECRET. The factory generates it; nothing was creating it, so every Karpenter
# node failed with
#   NodeClassReady=False  MetadataOptionsNotFound: Metadata TemplatesRef secret resource not found
#
# The factory's join_config is the right content by construction — this cluster's secrets, its network
# declaration, its time servers and the nocloud installer — and it deliberately carries no
# hostname-override, so each clone names itself after the VM Karpenter builds (the CCM needs the VM name
# to start with the node name).
# ---------------------------------------------------------------------------------------------
say "creating the Karpenter join secret from the factory's join_config"
join_cfg="$(mktemp)"; chmod 600 "$join_cfg"
trap 'rm -f "$KUBECONFIG_FILE" "$join_cfg"' EXIT
if ( cd "$ROOT" && tofu output -raw join_config ) > "$join_cfg" 2>/dev/null && [ -s "$join_cfg" ]; then
  kubectl -n kube-system create secret generic karpenter-talos-join \
    --from-file=user-data="$join_cfg" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  karpenter-talos-join: $(wc -c < "$join_cfg") bytes"
else
  echo "  SKIPPED: no join_config output — the NodeClass will not become Ready" >&2
fi

# ---------------------------------------------------------------------------------------------
# 5. The root Application, last: everything it needs to apply now exists.
# ---------------------------------------------------------------------------------------------
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

If cluster-base reports a discovery error for a CRD kind it just installed itself, that is ArgoCD's
discovery cache: delete and recreate the Application so it builds a fresh one. Restarting redis or the
application controller does NOT clear it (measured).
EOF
