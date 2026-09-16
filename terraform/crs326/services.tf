# The switch's own management services — the same adoption as the router's (`services.tf` in that
# module, where the whole story is written down), with one difference that decides how this diff reads.
#
# On the router, `api` was filtered to the compat subnets and that filter is what broke CI; here the
# service carries **no filter at all** (measured 2026-09-16: the login that fails on the RB5009 succeeds
# against this switch). So declaring an allow-list here is not a restatement — it is a *tightening*, and
# it is deliberate: the control plane of a device that holds the estate's L2 should not be reachable from
# every class just because the router's is not. Same policy on both devices, stated once per module
# because they are separate roots — `172.16.0.0/20` is the mgmt class (privilege lives there, Q27), and
# compat stays while it drains.
#
# If the plan shows this as a change, that is exactly what it is; the reviewed diff is the point.

locals {
  service_admin_sources = "172.16.0.0/20,172.16.100.0/24"
}

resource "routeros_ip_service" "api" {
  numbers = "api"
  port    = 8728
  address = local.service_admin_sources

  # Declared, not omitted — the provider plans `-> null` for an attribute the file leaves silent, i.e.
  # silence would clear a setting the device wants set.
  disabled = false
}
