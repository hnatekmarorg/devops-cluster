# Compat retirement

**Status:** Outstanding. Do this after the last device leaves the compat segment.

This runbook retires the compat segment (VLAN 1) after the last device has moved.

## Preconditions
- Every device has moved off compat.

## Steps
### 1. Remove resources
1. Remove the stale `vlan1-compat` comment from `terraform/routeros/stage2-filtering.tf`.
2. Remove the address adoption resource `routeros_ip_address.lan` from `terraform/routeros/stage2-filtering.tf`.
3. Remove the VLAN 1 bridge entry resource `routeros_interface_bridge_vlan.compat` from `terraform/routeros/stage2-filtering.tf`.

### 2. Update trunks
1. Set all trunks to tagged-only.
2. Set the `pvid` to `999` for all trunks.

### 3. Remove network services
1. Delete the compat DHCP scope.
2. Delete the compat address lists.

## Verification
1. Create one reviewed PR for these changes.
2. Run `tofu plan`.
3. Verify the plan shows exactly these deletions and no other changes.

## Rollback
1. Revert the PR.
2. Apply the previous configuration.

## Related documents
- `../../agent/migration-runbooks.md`
- `../../agent/vlan-port-assignment.md`
