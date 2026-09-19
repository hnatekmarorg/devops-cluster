#!/usr/bin/env bash
#
# teardown-cluster.sh — destroy a cluster in the one order that leaves nothing behind.
#
#   ./scripts/teardown-cluster.sh prod                 # interactive confirmation
#   ./scripts/teardown-cluster.sh prod --yes           # what CI runs
#   ./scripts/teardown-cluster.sh prod --yes --unmount-vault
#
# ---------------------------------------------------------------------------
# WHY `tofu destroy` IS NOT ENOUGH — and what each extra step buys
# ---------------------------------------------------------------------------
#   * **Karpenter's burst VMs are not in this root's state.** They belong to Karpenter, which is a
#     guest of the cluster: destroying the cluster removes the only thing that could ever clean them
#     up, and they keep running on balteus. Measured: a dev teardown left them, and they had to be
#     swept by hand. So drain the claims FIRST, while the API server is still there to be asked.
#
#   * **The vault's auth mount outlives the cluster.** `auth/kubernetes-<cluster>` holds the cluster's
#     CA and a TokenReview credential. A rebuild re-wires it, so this is hygiene rather than
#     correctness — but a mount pointing at a cluster that no longer exists is exactly the kind of
#     thing that gets discovered during an incident.
#
#   * **The router's reservations and DNS records are NOT torn down, deliberately.** They are the
#     cluster's fixed identities: keeping them is what makes a rebuild land on the same names and
#     addresses, so nothing that refers to the cluster by name has to change. Removing them is the
#     reverse of that decision and belongs in its own reviewed PR — this script prints the reminder
#     instead of doing it silently.
#
#   * **The state object is left in place** for the same reason: it is what a re-apply resumes from,
#     and deleting it turns "rebuild" into "discover that the VMs still exist". If the cluster is
#     gone for good, remove the key by hand as the last act, not the first.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER=""
ASSUME_YES=false
UNMOUNT_VAULT=false

for arg in "$@"; do
  case "$arg" in
  --yes) ASSUME_YES=true ;;
  --unmount-vault) UNMOUNT_VAULT=true ;;
  -h | --help)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*) echo "teardown-cluster: unknown option '$arg'" >&2; exit 64 ;;
  *)
    [[ -z "$CLUSTER" ]] || { echo "teardown-cluster: only one cluster at a time" >&2; exit 64; }
    CLUSTER="$arg"
    ;;
  esac
done

[[ -n "$CLUSTER" ]] || { echo "usage: teardown-cluster.sh <cluster> [--yes] [--unmount-vault]" >&2; exit 64; }

CLUSTER_ROOT="${REPO_ROOT}/terraform/clusters/${CLUSTER}"
# One state per cluster; the same derivation the workflows use.
STATE_KEY="cluster-${CLUSTER}/terraform.tfstate"
PVE_ENDPOINT="${PROXMOX_VE_ENDPOINT:-}"

log() { printf '  %s\n' "$*"; }
say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. What are we about to do, and is that what was meant?
# ---------------------------------------------------------------------------
say "cluster: ${CLUSTER}"
[[ -d "$CLUSTER_ROOT" ]] && log "root:   ${CLUSTER_ROOT}" ||
  log "root:   NOT PRESENT (the root was already deleted — destroy still works from the state)"
log "state:  ${STATE_KEY}"
log "action: drain Karpenter's claims, tofu destroy, sweep for leftovers"

if [[ "$ASSUME_YES" != "true" ]]; then
  printf '\nThis destroys the cluster and its VMs. Type the cluster name to confirm: '
  read -r reply
  [[ "$reply" == "$CLUSTER" ]] || { echo "  declined"; exit 1; }
fi

# ---------------------------------------------------------------------------
# 1. Init first. The drain below reads the kubeconfig from `tofu output`, which
#    needs the backend configured — and the order matters: without this the
#    drain silently skips on every CI run (no state, no kubeconfig), and the
#    only thing left to catch Karpenter's VMs is the sweep at the end, after
#    the API server is already gone.
# ---------------------------------------------------------------------------
if [[ -d "$CLUSTER_ROOT" ]]; then
  say "initialising the backend"
  if (cd "$CLUSTER_ROOT" && "${SCRIPT_DIR}/tofu-ci.sh" --role=none init -input=false >/dev/null 2>&1); then
    log "backend ready"
  else
    log "init FAILED — the drain will be skipped and the sweep at the end will report what is left"
  fi
else
  say "root directory is gone — skipping init (the CI job restores it from the parent commit)"
fi

# ---------------------------------------------------------------------------
# 2. Drain Karpenter's claims while the API server is still reachable.
#    Best-effort by design: the cluster may already be broken, which is a
#    perfectly good reason to be tearing it down.
# ---------------------------------------------------------------------------
say "draining Karpenter's claims (best effort)"
if KUBECONFIG_TMP="$(mktemp)" &&
  (cd "$CLUSTER_ROOT" 2>/dev/null && "${SCRIPT_DIR}/tofu-ci.sh" --role=none output -raw kubeconfig >"$KUBECONFIG_TMP" 2>/dev/null) &&
  [[ -s "$KUBECONFIG_TMP" ]]; then
  export KUBECONFIG="$KUBECONFIG_TMP"
  claims="$(kubectl get nodeclaims --no-headers 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "$claims" ]]; then
    log "claims: $(echo "$claims" | tr '\n' ' ')"
    # Deleting the claim is the only thing that makes Karpenter remove its VM.
    echo "$claims" | xargs -r kubectl delete nodeclaim --wait=false >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      remaining="$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l || echo 0)"
      [[ "$remaining" -eq 0 ]] && break
      sleep 5
    done
    log "claims remaining: $(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l || echo ?)"
  else
    log "no claims — nothing for Karpenter to clean up"
  fi
  rm -f "$KUBECONFIG_TMP"
else
  log "SKIPPED: no reachable kubeconfig (cluster already down?) — the sweep below covers the VMs"
  rm -f "$KUBECONFIG_TMP" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3. Destroy. This locks the state (unlike a plan) — writers are serialised.
# ---------------------------------------------------------------------------
say "tofu destroy"
if [[ ! -d "$CLUSTER_ROOT" ]]; then
  log "cannot run destroy without the root directory; if the root was deleted from git, the CI job"
  log "runs it from a checkout of the commit BEFORE the deletion. Nothing to do here."
else
  (cd "$CLUSTER_ROOT" && "${SCRIPT_DIR}/tofu-ci.sh" --role=none init -input=false >/dev/null &&
    "${SCRIPT_DIR}/tofu-ci.sh" --role=none destroy -input=false -auto-approve)
fi

# ---------------------------------------------------------------------------
# 4. Sweep: VMs the cluster owned that the state did not know about.
#    This is the step that catches Karpenter's orphans when step 1 could not
#    run (a cluster too broken to answer kubectl is exactly that case).
# ---------------------------------------------------------------------------
say "sweeping for leftover VMs named ${CLUSTER}-*"
if [[ -z "$PVE_ENDPOINT" || -z "${PROXMOX_VE_API_TOKEN:-}" ]]; then
  log "SKIPPED: PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN not set — check the hypervisor by hand:"
  log "  VMs whose name starts with '${CLUSTER}-' should be gone; the template is not one of them."
else
  found="$(curl -sfk -H "Authorization: PVEAPIToken=${PROXMOX_VE_API_TOKEN}" \
    "${PVE_ENDPOINT%/}/api2/json/cluster/resources?type=vm" 2>/dev/null |
    python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("data",[]):
    n=r.get("name") or ""
    if n.startswith(sys.argv[1] + "-"):
        print(f"{r.get(\"vmid\")} {n} {r.get(\"status\")} node={r.get(\"node\")}")
' "$CLUSTER" 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    log "STILL PRESENT — these need deleting by hand (they are not in any state):"
    echo "$found" | sed 's/^/    /'
    log "  delete each:  curl -sk -X DELETE -H \"Authorization: PVEAPIToken=\$TOKEN\" \\"
    log "                  \"\$PROXMOX_VE_ENDPOINT/api2/json/nodes/<node>/qemu/<vmid>\""
  else
    log "none — every VM the cluster owned is gone"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Opt-in: drop the vault's auth mount for this cluster.
# ---------------------------------------------------------------------------
if [[ "$UNMOUNT_VAULT" == "true" ]]; then
  say "unmounting the vault path"
  if [[ -z "${BAO_TOKEN:-}" ]] && [[ -r /etc/bao_token ]]; then BAO_TOKEN="$(cat /etc/bao_token)"; fi
  if [[ -z "${BAO_TOKEN:-}" ]]; then
    log "SKIPPED: no BAO_TOKEN and no readable /etc/bao_token"
  else
    BAO_ADDR="${BAO_ADDR:-https://bao.srv.hnatekmar.dev}"
    if BAO_ADDR="$BAO_ADDR" BAO_TOKEN="$BAO_TOKEN" bao auth disable "kubernetes-${CLUSTER}" 2>/dev/null; then
      log "auth/kubernetes-${CLUSTER} disabled"
    else
      log "SKIPPED: could not disable auth/kubernetes-${CLUSTER} (already gone, or not permitted)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. What this deliberately did not touch.
# ---------------------------------------------------------------------------
cat <<EOF

== left in place, on purpose

  router reservations + DNS   the cluster's fixed identities, so a rebuild lands on the same names
                              and addresses. Removing them is its own reviewed PR (the reverse of
                              the prerequisites PR) — do it only when the cluster is gone for good.

  the S3 state object         ${STATE_KEY}
                              what a re-apply resumes from. Delete it as the LAST act, not the first.

  the Proxmox template        9000 (talos-nocloud-template) — referenced as data, never managed here.
EOF
