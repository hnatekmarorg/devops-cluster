#!/usr/bin/env bash
#
# tofu-ci.sh — run OpenTofu for the RouterOS IaC track with the credentials and
# state-backend configuration that CI supplies.
#
# Contract (docs: terraform/README.md):
#   * Credentials come from the environment — mounted into the runner pod from a
#     cluster Secret, which keeps exactly one copy of them and needs no age key
#     in the pod — or, when absent, are decrypted from the sops dotenv file
#     terraform/secrets/enc.routeros-ci.env with the age key in
#     SOPS_AGE_KEY / SOPS_AGE_KEY_FILE (decision register Q14).
#   * The role decides WHICH credentials are used: `read` (RouterOS `agent-ro`)
#     for plan/drift, `write` (RouterOS `iac`) for apply. A pull request can
#     therefore never reach a write credential.
#   * State-backend flags are assembled from TF_STATE_* / AWS_* variables; no
#     bucket, endpoint or key is committed.
#   * Values are never printed. Only key NAMES and their presence are reported.
#
# Usage:
#   scripts/tofu-ci.sh check [--role=read|write]   # preflight; prints ready=true|false
#   scripts/tofu-ci.sh [--role=read|write] <tofu args...>
#
#   run from the module directory, e.g.
#     ../../scripts/tofu-ci.sh --role=read plan -input=false -lock-timeout=5m
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENC_FILE="${TF_CI_SECRET_FILE:-${REPO_ROOT}/terraform/secrets/enc.routeros-ci.env}"

log() { printf '%s\n' "$*" >&2; } # diagnostics on stderr; stdout stays machine-readable

# ---------------------------------------------------------------------------
# Which state does this root address?
#
# TF_STATE_KEY used to default to `routeros/rb5009.tfstate` for EVERY root, which
# is a live footgun rather than a convenience: run a cluster root without setting
# it and the plan, apply or destroy silently addresses the ROUTER's state. Found
# the hard way — `init -migrate-state` in terraform/clusters/dev was pointed at
# the router's key. Nothing was lost that time (an empty local state does not
# overwrite a populated remote one, verified: the router's state still read 134
# resources), but the failure mode is "destroy the wrong infrastructure".
#
# So the default is now DERIVED FROM THE ROOT, and an unrecognised root is a hard
# error rather than a silent fallback. One state per root, stated where the root
# is, is the property worth having.
# ---------------------------------------------------------------------------
derive_state_key() {
  [[ -n "${TF_STATE_KEY:-}" ]] && return 0

  local derived=""
  case "$PWD" in
  */terraform/routeros) derived="routeros/rb5009.tfstate" ;;
  */terraform/crs326) derived="crs326/crs326.tfstate" ;;
  */terraform/clusters/*) derived="cluster-$(basename "$PWD")/terraform.tfstate" ;;
  esac

  if [[ -z "$derived" ]]; then
    log "tofu-ci: TF_STATE_KEY is not set and this root has no known state key:"
    log "         $PWD"
    log "         Set it explicitly (TF_STATE_KEY=<key>) rather than letting this tool guess —"
    log "         guessing is how a root ends up addressing another root's infrastructure."
    exit 64
  fi

  export TF_STATE_KEY="$derived"
  log "tofu-ci: TF_STATE_KEY not set — derived '${TF_STATE_KEY}' from ${PWD##*/}/"
}

ROLE="read"
if [[ "${1:-}" == --role=* ]]; then
  ROLE="${1#--role=}"
  shift
fi

derive_state_key

user_key=""
pass_key=""
case "$ROLE" in
read)
  user_key=ROS_READ_USERNAME
  pass_key=ROS_READ_PASSWORD
  ;;
write)
  user_key=ROS_WRITE_USERNAME
  pass_key=ROS_WRITE_PASSWORD
  ;;
none)
  # A root that talks to neither the router nor anything else with its own
  # identity: the cluster roots. They authenticate to Proxmox with
  # PROXMOX_VE_* (supplied by the job, read by the bpg provider directly) and
  # to the state bucket with AWS_*, so there is no role pair to resolve. Before
  # this existed the apply died at exit 78 *before* touching Proxmox, with a
  # message about RouterOS credentials that had nothing to do with the job.
  user_key=""
  pass_key=""
  ;;
*)
  log "tofu-ci: unknown role '${ROLE}' (expected read|write|none)"
  exit 64
  ;;
esac

# ---------------------------------------------------------------------------
# credentials
# ---------------------------------------------------------------------------
CRED_SOURCE=""

resolve_creds() {
  if [[ "$ROLE" == "none" ]]; then
    CRED_SOURCE="none required (the provider authenticates itself)"
    return 0
  fi
  if [[ -n "${!user_key:-}" && -n "${!pass_key:-}" ]]; then
    CRED_SOURCE="job environment (repo/environment secret, or mounted into the runner)"
  elif [[ -f "$ENC_FILE" ]]; then
    if [[ -z "${SOPS_AGE_KEY:-}" && -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
      log "tofu-ci: ${ENC_FILE} exists but neither SOPS_AGE_KEY nor SOPS_AGE_KEY_FILE is set"
      return 1
    fi
    local decrypted line name value
    if ! decrypted="$(sops -d "$ENC_FILE" 2>/dev/null)"; then
      log "tofu-ci: sops could not decrypt ${ENC_FILE} (wrong or missing age key?)"
      return 1
    fi
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == '#'* ]] && continue
      name="${line%%=*}"
      value="${line#*=}"
      value="${value%\"}"
      value="${value#\"}" # tolerate KEY="value"
      case "$name" in
      ROS_READ_USERNAME | ROS_READ_PASSWORD | ROS_WRITE_USERNAME | ROS_WRITE_PASSWORD | \
        PROXMOX_VE_* | \
        TF_STATE_* | AWS_*) export "${name}=${value}" ;;
      esac
    done <<<"$decrypted"
    unset decrypted
    CRED_SOURCE="sops (${ENC_FILE#"$REPO_ROOT"/})"
    if [[ -z "${!user_key:-}" || -z "${!pass_key:-}" ]]; then
      log "tofu-ci: decrypted secret has no ${user_key}/${pass_key} for role '${ROLE}'"
      return 1
    fi
  else
    log "tofu-ci: no credentials for role '${ROLE}' — ${user_key}/${pass_key} absent and ${ENC_FILE#"$REPO_ROOT"/} not present"
    return 1
  fi

  # The provider reads ROS_USERNAME/ROS_PASSWORD; the role pair is only the
  # selector, so it is mapped here and the selector copies are dropped.
  export ROS_USERNAME="${!user_key}"
  export ROS_PASSWORD="${!pass_key}"
  return 0
}

# ---------------------------------------------------------------------------
# state backend
# ---------------------------------------------------------------------------
backend_args() {
  if [[ -z "${TF_STATE_BUCKET:-}" || -z "${TF_STATE_ENDPOINT:-}" ]]; then
      log "tofu-ci: s3 backend needs TF_STATE_BUCKET and TF_STATE_ENDPOINT (MinIO)"
      return 1
    fi
    printf -- '-backend-config=bucket=%s\n' "$TF_STATE_BUCKET"
    printf -- '-backend-config=key=%s\n' "$TF_STATE_KEY"
    printf -- '-backend-config=region=%s\n' "${TF_STATE_REGION:-us-east-1}"
    printf -- '-backend-config=endpoint=%s\n' "$TF_STATE_ENDPOINT"
    # MinIO is not AWS: the STS/IAM validation calls do not exist there, and
    # it wants path-style addressing.
    printf -- '-backend-config=use_path_style=true\n'
    printf -- '-backend-config=skip_credentials_validation=true\n'
    printf -- '-backend-config=skip_requesting_account_id=true\n'
    # MinIO advertises a region name that is not an AWS region (`europe`), and
    # the AWS SDK rejects unknown region names client-side before any request
    # is made: "invalid AWS Region: europe". Skipping validation lets the
    # backend sign with the region MinIO actually advertises, which is the one
    # value that cannot be wrong. Measured, not guessed.
    printf -- '-backend-config=skip_region_validation=true\n'
    # Locking lives in the bucket itself (OpenTofu >= 1.10, Q8) — no
    # DynamoDB, no extra service to be down.
  printf -- '-backend-config=use_lockfile=true\n'
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
preflight() {
  local ok=true

  if resolve_creds; then
    log "tofu-ci: credentials OK for role '${ROLE}' (source: ${CRED_SOURCE}; values never printed)"
  else
    ok=false
  fi

  if [[ -n "${TF_STATE_BUCKET:-}" && -n "${TF_STATE_ENDPOINT:-}" ]]; then
    log "tofu-ci: state backend s3 — bucket and endpoint present (key: ${TF_STATE_KEY})"
  else
    log "tofu-ci: state backend s3 — TF_STATE_BUCKET/TF_STATE_ENDPOINT missing"
    ok=false
  fi

  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    log "tofu-ci: state credentials present (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)"
  else
    log "tofu-ci: state credentials missing (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)"
    ok=false
  fi

  # A cluster root authenticates to Proxmox, not to RouterOS, so the "is CI armed?" question is
  # answered by these two. Without them the plan dies with `Error: Missing Proxmox VE API Endpoint` —
  # a failure that reads like a code problem and is configuration. Same rule as the router's preflight:
  # an un-armed CI must not block reviews, it must say which piece is missing.
  if [[ "$ROLE" == "none" ]]; then
    if [[ -n "${PROXMOX_VE_ENDPOINT:-}" && -n "${PROXMOX_VE_API_TOKEN:-}" ]]; then
      log "tofu-ci: proxmox credentials present (PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN)"
    else
      log "tofu-ci: proxmox credentials missing — set PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN as"
      log "         secrets on the environment this job uses (clusters-production for the cluster roots)"
      ok=false
    fi
  else
    log "tofu-ci: ROS_HOSTURL=${ROS_HOSTURL:-<unset>}"
  fi

  if [[ "$ok" == "true" ]]; then
    echo "ready=true"
  else
    echo "ready=false"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
cmd="${1:-}"
[[ -n "$cmd" ]] || {
  log "usage: tofu-ci.sh [--role=read|write] check|<tofu args...>"
  exit 64
}

if [[ "$cmd" == "check" ]]; then
  preflight
  exit $?
fi
shift

case "$cmd" in
init)
  resolve_creds || exit 78
  if ! bargs="$(backend_args)"; then exit 78; fi
  bargs_arr=()
  if [[ -n "$bargs" ]]; then mapfile -t bargs_arr <<<"$bargs"; fi
  unset bargs
  log "tofu-ci: init (role ${ROLE}, backend s3)"
  exec tofu init -input=false "${bargs_arr[@]}" "$@"
  ;;
plan | apply | refresh | import | destroy | taint | untaint)
  # Anything that reads or writes the device needs a RouterOS identity.
  resolve_creds || exit 78
  log "tofu-ci: ${cmd} (role ${ROLE}, credentials from ${CRED_SOURCE})"
  exec tofu "$cmd" "$@"
  ;;
show | output | state | force-unlock)
  # State-only operations: they never talk to the router, so requiring an identity here is
  # wrong and was actively harmful — the apply job carries *only* the write pair (that
  # separation is deliberate), and its post-apply summary asked for the default `read` role,
  # dying with exit 78 *after* a successful apply. A reporting step must never be able to
  # fail a run that already changed the device.
  log "tofu-ci: ${cmd} (state only — no RouterOS identity required)"
  exec tofu "$cmd" "$@"
  ;;
*)
  # fmt / validate / version / providers — no credentials, no state.
  exec tofu "$cmd" "$@"
  ;;
esac
