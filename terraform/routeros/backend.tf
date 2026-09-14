# Partial backend configuration: every value is supplied at init time by
# ../scripts/tofu-ci.sh from TF_STATE_* / AWS_* environment variables, so no
# bucket, endpoint or credential is committed here.
#
# Default target = MinIO on the devops cluster (decision register Q8: S3 +
# lockfile locking; it wins on break-glass because a laptop on the LAN can still
# read the state while the cluster is down).
#
# Alternative (no MinIO dependency): the `kubernetes` backend, see
# Every value below is injected at init time by scripts/tofu-ci.sh (roles, not env guesses).
# That trades away break-glass readability, which is why it is not the default.
terraform {
  backend "s3" {}
}
