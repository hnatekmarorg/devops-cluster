# Partial S3 backend: every value is injected at init time by scripts/tofu-ci.sh from role-scoped
# configuration. The key is per module, so the two devices never share a state file.
terraform {
  backend "s3" {}
}
