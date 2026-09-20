#!/usr/bin/env bash
# Seed the vault DATA that wire-vault.sh's policies exist for.
#
#   BAO_TOKEN=... CF_API_TOKEN=... TRUENAS_CSI_API_KEY=... ./scripts/seed-vault.sh common
#   BAO_TOKEN=... ./scripts/seed-vault.sh check dev prod
#
# WHY THIS EXISTS. wire-vault.sh wires the auth mount and the read policy — it never writes a value.
# `secret/dev/cloudflare` therefore came from a hand-run `bao kv put` that nobody captured, and
# `secret/prod/*` did not exist at all. The discovery was expensive in a specific way: the
# ClusterSecretStore reported Valid (its check exercises the AUTH, not the data path), so prod looked
# wired while cert-manager sat on `SecretSyncedError: Secret does not exist` — which reads like a
# permissions problem and is not one.
#
# `common` is idempotent and does NOT overwrite: re-running it after a rotation is a no-op, and a
# rotation is the deliberate `--force`. Values travel in the request BODY, never in argv where the
# process list would expose them.
#
# TOKEN SCOPE: writing needs create/update on `secret/data/common/*`. The CI provisioning token
# (`k8s-bootstrap`) deliberately cannot read or write secrets, so this runs with an operator token —
# NOT the one wire-vault.sh uses in CI.
set -euo pipefail

MODE="${1:?usage: BAO_TOKEN=... seed-vault.sh common [--force] | seed-vault.sh check <cluster> [<cluster>...]}"
shift

BAO_ADDR="${BAO_ADDR:-https://bao.srv.hnatekmar.dev}"
if [ -z "${BAO_TOKEN:-}" ] && [ -r /etc/bao_token ]; then
  BAO_TOKEN="$(tr -d '\n' < /etc/bao_token)"
fi
[ -n "${BAO_TOKEN:-}" ] || { echo "no vault token: set BAO_TOKEN or place one in /etc/bao_token" >&2; exit 1; }

# curl rather than the CLI: the CLI takes key=value in argv, which is visible in the process list.
CURL=(curl -sS -H "X-Vault-Token: ${BAO_TOKEN}")

# A value needing JSON escaping is refused rather than silently corrupted into the request.
jsonable() { # jsonable <value> <key>
  [ -n "$1" ] || { echo "refusing: empty value for '$2'" >&2; exit 1; }
  case "$1" in
    *\"*|*\\*|*$'\n'*) echo "refusing: the value for '$2' contains a quote, backslash or newline" >&2; exit 1;;
  esac
}

exists() { # exists <path-inside-mount>
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${BAO_TOKEN}" \
            "${BAO_ADDR}/v1/secret/metadata/$1")"
  case "$code" in
    200) return 0;;
    404) return 1;;
    *)   echo "unexpected HTTP $code reading metadata for $1" >&2; exit 1;;
  esac
}

put() { # put <path-inside-mount> <key> <value>
  local path="$1" key="$2" value="$3" body resp
  jsonable "$value" "$key"
  body="$(printf '{"data":{"%s":"%s"}}' "$key" "$value")"
  if ! resp="$(printf '%s' "$body" | "${CURL[@]}" -X POST --data-binary @- \
                 "${BAO_ADDR}/v1/secret/data/${path}")"; then
    echo "  FAILED writing secret/${path}: ${resp}" >&2
    exit 1
  fi
  echo "  wrote secret/${path} (key: ${key})"
}

case "$MODE" in
  common)
    FORCE=false
    if [ "${1:-}" = "--force" ]; then
      FORCE=true
    fi

    printf '\n== shared values -> secret/common/*\n'
    : "${CF_API_TOKEN:?CF_API_TOKEN is not set — the Cloudflare token that issues the cluster certs}"
    if exists common/cloudflare && [ "$FORCE" = false ]; then
      echo "  secret/common/cloudflare exists — left alone (--force to overwrite)"
    else
      put common/cloudflare api-token "$CF_API_TOKEN"
    fi

    : "${TRUENAS_CSI_API_KEY:?TRUENAS_CSI_API_KEY is not set — the NAS API key the CSI driver uses}"
    if exists common/truenas-csi && [ "$FORCE" = false ]; then
      echo "  secret/common/truenas-csi exists — left alone (--force to overwrite)"
    else
      put common/truenas-csi api-key "$TRUENAS_CSI_API_KEY"
    fi

    cat <<'EOF'

Shared values seeded. A cluster reaches them through the `common/*` grant in its read policy
(scripts/wire-vault.sh), and cluster-base references them by path:

  certManager.eso.vaultKey      -> common/cloudflare
  storage.truenasCsi.vaultKey   -> common/truenas-csi

Verify what a given cluster will actually find:

  ./scripts/seed-vault.sh check dev prod
EOF
    ;;

  check)
    [ "$#" -gt 0 ] || { echo "check needs at least one cluster name" >&2; exit 2; }
    rc=0
    for c in "$@"; do
      printf '\n== %s\n' "$c"
      for path in common/cloudflare common/truenas-csi; do
        if exists "$path"; then
          echo "  ok      secret/${path}"
        else
          echo "  MISSING secret/${path}  <- its ExternalSecret fails 'Secret does not exist'"
          rc=1
        fi
      done
      if "${CURL[@]}" -X LIST "${BAO_ADDR}/v1/secret/metadata/${c}" 2>/dev/null | grep -q '"keys"'; then
        echo "  ok      secret/${c}/ carries per-cluster values"
      else
        echo "  note    secret/${c}/ is empty or absent (fine unless this cluster's values use it)"
      fi
    done
    exit "$rc"
    ;;

  *)
    echo "unknown mode '$MODE' (use: common | check)" >&2
    exit 2
    ;;
esac
