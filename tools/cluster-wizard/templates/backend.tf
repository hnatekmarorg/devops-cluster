# Partial backend, exactly like the other roots: every value is injected at init time
# (TF_STATE_* / AWS_*) so no bucket, endpoint or credential is committed.
#
# The KEY is this cluster's own — one state per cluster is the point, because clusters get destroyed and
# rebuilt independently and a shared state would make one cluster's rebuild a risk to the other.
# scripts/tofu-ci.sh derives it from the directory name, so CI needs nothing else:
#
#   tofu init -reconfigure -backend-config="key={{.StateKey}}"
terraform {
  backend "s3" {}
}
