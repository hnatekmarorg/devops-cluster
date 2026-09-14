# Credentials and endpoint deliberately come from the environment: the provider
# reads ROS_HOSTURL / ROS_USERNAME / ROS_PASSWORD (plus ROS_INSECURE or
# ROS_CA_CERTIFICATE) by itself, which is how CI injects them from a cluster
# Secret. Nothing sensitive belongs in this file.
#
# Verified transport (vault note "traps"):
#   api://172.16.100.1:8728    plaintext API   <- what CI uses
#   apis://172.16.100.1:8729   TLS handshake FAILS: no certificate is bound to
#                              the api-ssl service. Move to TLS only after a cert
#                              is installed, then pin it with ROS_CA_CERTIFICATE
#                              and set ROS_INSECURE=false.
#
# The RouterOS API listens on the LAN subnets only (never internet-exposed),
# which is exactly why the workflows run on the in-cluster, on-LAN runner
# instead of a GitHub-hosted one.
provider "routeros" {}
