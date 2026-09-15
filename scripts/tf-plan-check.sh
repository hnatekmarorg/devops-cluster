#!/usr/bin/env bash
# Plan a module from a FRESH origin/main checkout, without touching your working tree.
#
# Why this exists: reading a plan from whatever branch happens to be checked out has twice
# proposed destroying objects a later merge had created (bridge VLAN entries, DHCP scopes) — a
# stale tree is indistinguishable from real drift in the output. This script removes the choice:
# it fetches, extracts the module from origin/main into a temp directory, and plans there.
#
# Usage:  source the credentials first, then run it.
#   set -a; . /root/network-migration/credentials/routeros.env; . /root/network-migration/credentials/minio.env; set +a
#   ./scripts/tf-plan-check.sh [module]        # module defaults to routeros
#
# Prints the plan summary and the resource-level actions. Read-only: -lock=false, no -out.

set -euo pipefail
module="${1:-routeros}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET (and TF_STATE_ENDPOINT/REGION/KEY) first}"
: "${ROS_HOSTURL:?set ROS_HOSTURL first}"

cd "$repo_root"
git fetch -q origin main
git archive origin/main "terraform/${module}" | tar -x -C "$work" --strip-components=2
cd "$work"

echo "tf-plan-check: module '${module}' from origin/main ($(git -C "$repo_root" rev-parse --short origin/main))"
tofu init -input=false \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY:-${module}/rb5009.tfstate}" \
  -backend-config="region=${TF_STATE_REGION:-europe}" \
  -backend-config="endpoint=${TF_STATE_ENDPOINT}" \
  -backend-config=use_path_style=true \
  -backend-config=skip_credentials_validation=true \
  -backend-config=skip_requesting_account_id=true \
  -backend-config=skip_region_validation=true \
  -backend-config=use_lockfile=true >/dev/null

plan_file="$work/plan.txt"
set +e
tofu plan -input=false -no-color -lock=false >"$plan_file" 2>&1
rc=$?
set -e

grep -aE "^Plan: [0-9]+ to|No changes" "$plan_file" || true
echo "--- resource actions"
grep -aE "^  # .* will be (created|updated|destroyed|imported)|will be read during apply" "$plan_file" || true
if grep -qa "will be destroyed" "$plan_file"; then
  echo
  echo "NOTE: this plan destroys something. Before acting on it, check that origin/main is current"
  echo "      and that the object is not something a later merge created."
fi
exit "$rc"
