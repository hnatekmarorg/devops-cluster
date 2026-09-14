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

log() { printf '%s\n' "$*" >&2; }   # diagnostics on stderr; stdout stays machine-readable

ROLE="read"
if [[ "${1:-}" == --role=* ]]; then
  ROLE="${1#--role=}"
  shift
fi

user_key=""
pass_key=""
case "$ROLE" in
  read)  user_key=ROS_READ_USERNAME;  pass_key=ROS_READ_PASSWORD ;;
  write) user_key=ROS_WRITE_USERNAME; pass_key=ROS_WRITE_PASSWORD ;;
  *) log "tofu-ci: unknown role '${ROLE}' (expected read|write)"; exit 64 ;;
esac

# ---------------------------------------------------------------------------
# credentials
# ---------------------------------------------------------------------------
CRED_SOURCE=""

resolve_creds() {
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
      value="${value%\"}"; value="${value#\"}"     # tolerate KEY="value"
      case "$name" in
        ROS_READ_USERNAME|ROS_READ_PASSWORD|ROS_WRITE_USERNAME|ROS_WRITE_PASSWORD|\
        TF_STATE_*|AWS_*) export "${name}=${value}" ;;
      esac
    done <<< "$decrypted"
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
  case "${TF_STATE_BACKEND:-s3}" in
    s3)
      if [[ -z "${TF_STATE_BUCKET:-}" || -z "${TF_STATE_ENDPOINT:-}" ]]; then
        log "tofu-ci: s3 backend needs TF_STATE_BUCKET and TF_STATE_ENDPOINT (MinIO)"
        return 1
      fi
      printf -- '-backend-config=bucket=%s\n'   "$TF_STATE_BUCKET"
      printf -- '-backend-config=key=%s\n'      "${TF_STATE_KEY:-routeros/rb5009.tfstate}"
      printf -- '-backend-config=region=%s\n'   "${TF_STATE_REGION:-us-east-1}"
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
      ;;
    kubernetes)
      # Values live in backend.tf (see backend-kubernetes.tf.example).
      ;;
    *)
      log "tofu-ci: unknown TF_STATE_BACKEND '${TF_STATE_BACKEND}' (expected s3|kubernetes)"
      return 1
      ;;
  esac
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

  if [[ "${TF_STATE_BACKEND:-s3}" == "kubernetes" ]]; then
    log "tofu-ci: state backend kubernetes (configured in backend.tf)"
  elif [[ -n "${TF_STATE_BUCKET:-}" && -n "${TF_STATE_ENDPOINT:-}" ]]; then
    log "tofu-ci: state backend s3 — bucket and endpoint present (key: ${TF_STATE_KEY:-routeros/rb5009.tfstate})"
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

  log "tofu-ci: ROS_HOSTURL=${ROS_HOSTURL:-<unset>}"

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
[[ -n "$cmd" ]] || { log "usage: tofu-ci.sh [--role=read|write] check|<tofu args...>"; exit 64; }

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
    if [[ -n "$bargs" ]]; then mapfile -t bargs_arr <<< "$bargs"; fi
    unset bargs
    log "tofu-ci: init (role ${ROLE}, backend ${TF_STATE_BACKEND:-s3})"
    exec tofu init -input=false "${bargs_arr[@]}" "$@"
    ;;
  plan|apply|refresh|show|output|state|import|destroy|force-unlock|taint|untaint)
    resolve_creds || exit 78
    log "tofu-ci: ${cmd} (role ${ROLE}, credentials from ${CRED_SOURCE})"
    exec tofu "$cmd" "$@"
    ;;
  *)
    # fmt / validate / version / providers — no credentials, no state.
    exec tofu "$cmd" "$@"
    ;;
esac
