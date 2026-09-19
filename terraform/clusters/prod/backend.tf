# Partial backend, exactly like the other roots: every value is injected at init time
# (TF_STATE_* / AWS_*) so no bucket, endpoint or credential is committed.
#
# The KEY is this cluster's own — one state per cluster is the point, because clusters get destroyed and
# rebuilt independently and a shared state would make one cluster's rebuild a risk to the other:
#
#   tofu init -reconfigure -backend-config="key=cluster-prod/terraform.tfstate"
#
# scripts/tofu-ci.sh still has a single default key, so until it grows a per-root map, a CI apply for this
# root needs the key passed explicitly (see the scope list in this PR).
terraform {
  backend "s3" {}
}
