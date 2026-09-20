# Router bootstrap runbook — the one-time steps only you can do

Companion to `README.md` (contracts) and `docs/agent/network-wiring.md` (measured state). Every
step here is a **bootstrap exception**: it exists because the credential or the console
access it creates cannot be created by the thing it protects. Each one names its
verification, and each is deleted from here once it becomes automatable.

Recommended order: **0 → 1 → 4 → 2** (backups first, then hygiene, then the retirement that
needs no new credentials, then the new write user). The WAN change is a separate window and
has its own PR.

---

## 0. Backups that can actually be restored (all three devices)

The API cannot read file contents, so these must be produced *and* pulled off the device by
hand. Status before you start: CRS326 ✓ and CRS804 ✓ already have `pre-overhaul-20260914`
(backup + rsc); **the RB5009 has none**, and it is the device the module manages.

Fix the clocks first, or the filenames lie — the CRS326's clock was nine days behind and the
RB5009's file timestamps read 1970:

```
/system clock print
/system ntp client set enabled=yes
/system ntp client servers add address=pool.ntp.org
```

Then, per device (RB5009, CRS326, CRS804):

```
/system backup save name=pre-overhaul-<yyyymmdd>-<device>
/export show-sensitive file=pre-overhaul-<yyyymmdd>-<device>
```

Pull the files off the device (any one of these):

* **WinBox** → Files → select both files → drag them to your desktop (simplest);
* `scp admin@172.16.100.1:<file> /root/network-migration/backups/` — needs the `ftp` policy
  on your admin user and file transfer enabled;
* SFTP with the same credentials.

Drop them in `/root/network-migration/backups/` (root-only, outside git and the vault) —
then tell me and I will verify names/sizes/dates from the API and update the backups README
so the rollback artefact is recorded, not assumed.

**Why this matters:** a router changed by CI needs a restore path that is *not* on the
router. `/export` over the API returns nothing, so this is the only way.

---

## 1. Read-user hygiene — one command per device

The agent's read user currently carries `sensitive` (plus `sniff`, `romon`, `password`,
`web`, `winbox`, `telnet`, `ssh`), which is both wider than agreed and secret-exposing: a
**WireGuard private key came back through a read once**.

```
/user group set read policy=api,read,test
```

(WinBox: System → Users → Groups → `read` → clear every policy except `api`, `read`, `test`.)

Notes:

* this makes the read user **API-only** — no WinBox, no web, no SSH — which is what a
  service account should be;
* RouterOS then **redacts** keys/PSKs/passwords on reads instead of returning them.

Verify:

```
/user group print where name=read
/user print detail where group=read
```

Then tell me: I re-run the read-only smoke test from the Hermes host and confirm both that
the API still works and that secret material is now redacted.

---

## 2. The `iac` write user (RB5009 first)

```
/user group add name=iac policy=api,read,write,test comment="CI write user (router IaC)"
/user add name=iac group=iac comment="CI write user (router IaC)"
/user set iac password="<your generated password>"
```

Leave `address=` unrestricted at first: the CI source address is whichever node egresses to
the router, not a fixed host — tighten it later once the workspaces are known to
authenticate.

The password has to reach CI **without passing through chat**. Two ways, pick one:

| Option | What you do |
|---|---|
| **A — you set it** | GitHub → Settings → Environments → *New environment* `routeros-production` (add yourself as required reviewer) → then add secrets `ROS_WRITE_USERNAME=iac` and `ROS_WRITE_PASSWORD=<generated>` |
| **B — I set it** | Write `/root/network-migration/credentials/routeros-iac.env` (mode 600) with `ROS_WRITE_USERNAME=iac` and `ROS_WRITE_PASSWORD=<generated>`; I read it from the filesystem and set the environment secrets with the bot token, values never echoed |

Verify (after the secrets exist, either way): `gh secret list --repo hnatekmarorg/devops-cluster --env routeros-production`
shows the names, and the `tf-apply` preflight switches from *skip* to *ready*.

---

## 3. Arming, once the review is done

* Repo variable **`ROUTEROS_CI_ENABLED=true`** (Settings → Variables).
* Until then `tf-apply` and `tf-drift` log that they skipped and stay green — deliberately,
  so merging the pipeline cannot produce a surprise apply.
* Optional first run: Actions → `tf-apply (routeros)` → *Run workflow* to watch the
  plan/apply path once, on a change you have already reviewed.

---

## 4. Same window: retire the orphaned WireGuard interface

```
/interface wireguard print
/interface wireguard remove [find name=vpn]
```

It has **zero peers** and its private key leaked into a transcript — deleting the interface
disposes of the key. The planned VPN (phase 5) creates a fresh one with a new key.

Verify: `/interface wireguard print` returns nothing, and `/interface print where name~"vpn"`
shows no leftovers.

---

## 5. The WAN change

Separate window, separate PR: take `ether5` out of the bridge and move the PPPoE client onto
it, so the WAN stops sharing the LAN's L2 domain. The PR body carries the exact steps, the
four post-change checks, and the rollback (`/system backup` restore from step 0).
