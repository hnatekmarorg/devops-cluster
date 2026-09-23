# Router bootstrap

**Status:** Partly outstanding. Check the list in the agent source before you start.

This runbook describes the one-time bootstrap steps for the RB5009. Use this runbook to set up backups, user hygiene, and CI access.

## Preconditions

- You have console access to the RB5009.
- You have access to a machine with WinBox or SCP.

## Steps

### 1. Backups

Perform these steps first for all three RouterOS devices (RB5009, CRS326, CRS804). Fix the clocks to ensure correct filenames.
**NOTE:** The RB5009 had no backup at the time of writing.

Run these commands on the device:
```
/system clock print
/system ntp client set enabled=yes
/system ntp client servers add address=pool.ntp.org
```
The clock now syncs with NTP.

Create the backup and export files:
```
/system backup save name=pre-overhaul-<yyyymmdd>-<device>
/export show-sensitive file=pre-overhaul-<yyyymmdd>-<device>
```
The device creates two files in the file list.

Pull the files from the device to `/root/network-migration/backups/` using WinBox or SCP.
**NOTE:** Store these files outside of git and the vault.

### 2. Read-user hygiene

Limit the read user policies to prevent secret leaks.

Run this command on the RB5009:
```
/user group set read policy=api,read,test
```
The read user is now API-only. RouterOS now redacts secrets on read.

Verify the change:
```
/user group print where name=read
/user print detail where group=read
```
The output shows only the api, read, and test policies.

### 3. Retire orphaned WireGuard interface

Delete the old VPN interface to dispose of the leaked private key.

Run these commands on the RB5009:
```
/interface wireguard print
/interface wireguard remove [find name=vpn]
```
The interface is now deleted.

Verify the deletion:
```
/interface wireguard print
/interface print where name~"vpn"
```
The output returns nothing.

### 4. Create the iac write user

Create a dedicated user for the CI pipeline.

Run these commands on the RB5009:
```
/user group add name=iac policy=api,read,write,test comment="CI write user (router IaC)"
/user add name=iac group=iac comment="CI write user (router IaC)"
/user set iac password="<your generated password>"
```
The iac user now has write access via the API.

Add the password to GitHub secrets in the `routeros-production` environment. Use the name `ROS_WRITE_PASSWORD`. Use `iac` for `ROS_WRITE_USERNAME`.

Verify the secrets:
```
gh secret list --repo hnatekmarorg/devops-cluster --env routeros-production
```
The output shows the ROS_WRITE_USERNAME and ROS_WRITE_PASSWORD secrets.

### 5. Arm the CI pipeline

Enable the RouterOS CI variable.

Set the GitHub repository variable **`ROUTEROS_CI_ENABLED=true`** in Settings -> Variables.
The CI pipeline now performs plan and apply actions.

## Verification

- The `tf-apply` preflight check shows as ready.
- The read-only smoke test from the Hermes host succeeds.
- Secret material is redacted in API read responses.

## Rollback

Restore the system from the backup created in Step 1. The restore path is the backup file.

## Related documents

- Agent source: `../../agent/router-bootstrap-runbook.md`
- Human map: `../infra-map.md`
