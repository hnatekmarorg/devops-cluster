# Partial backend, exactly like the other roots: every value is injected at init time
# (TF_STATE_* / AWS_*) so no bucket, endpoint or credential is committed.
#
# NOTE for a per-cluster root: the shared CI helper injects ONE state key, so a new root needs either its
# own key passed at init (-backend-config="key=cluster-dev/terraform.tfstate") or a per-root entry in
# scripts/tofu-ci.sh. One key per cluster is the point — clusters get destroyed and rebuilt independently.
terraform {
  backend "s3" {}
}
