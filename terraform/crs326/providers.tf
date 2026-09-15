# Empty on purpose: the endpoint and credentials arrive as ROS_* environment variables, resolved
# from the role-scoped configuration by scripts/tofu-ci.sh. A provider block with values in it is a
# second place for the same truth to live.
provider "routeros" {}
