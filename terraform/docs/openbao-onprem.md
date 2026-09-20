# OpenBao on-prem (LXC 120) — as-built runbook

**Status:** working. Unsealed, active, raft leader, KV v2 at `secret/`, snapshotted daily, restore drill passed.
**Last verified:** 2026-09-17.

## What it is

| | |
|---|---|
| host | LXC **120** on balteus, `172.16.40.33` (srv), Rocky Linux 9.6 |
| name | `bao.srv.hnatekmar.dev` — reserved in `dhcp.tf`, record derived from it. Two labels on purpose: `*.hnatekmar.dev` matches one, so this name resolves on the LAN and nowhere else |
| service | `/usr/lib/systemd/system/openbao.service` (`bao server -config=/etc/openbao/openbao.hcl`), user `openbao`, enabled at boot |
| version | **2.6.2** — matched to the Hetzner instance so its raft snapshots can be restored here (a newer snapshot will not load into an older instance) |
| storage | **raft**, `/var/lib/openbao/data`, `node_id = "openbao-0"` |
| seal | shamir, **1 share / 1 threshold** — `bao operator rekey` changes this later |
| listener | **loopback only** (`127.0.0.1:8200/:8201`) — nothing talks cleartext to a vault across the wire |
| engines | KV v2 at `secret/`; auth: `token/` only (approle + kubernetes to come) |

## How it was built (and what was replaced)

The LXC template shipped **`bao-hsm` 2.4.1**, a stock upstream example config, `file` storage at
`/opt/openbao/data`, and — the important part — a **pre-initialised vault**. Every container cloned from
that template shares the same master key, so the vault was rebuilt rather than adopted:

1. `bao-hsm 2.4.1` → **`openbao 2.6.2`** (rpm, sha256 verified against the release `checksums.txt`)
2. `file` storage → **raft** (the file backend is what produced the 2M-small-files inode exhaustion noted in
   the Hetzner chart's own comments)
3. the template's data dir was **renamed, not deleted**: `/opt/openbao/data.template-<stamp>`
4. its config preserved as `/etc/openbao/openbao.hcl.template-<stamp>`
5. hostname corrected: `openabo.hnatekmar.xyz` → `openbao.srv.hnatekmar.dev` (it was missing a `b`)

## Gotchas worth remembering

- **OpenBao 2.6 dropped `disable_mlock`** — logged as a warning only, harmless noise.
- **raft requires a top-level `cluster_addr`.** Without it the process exits with
  `cluster address must be set when using raft storage` and systemd reports only an exit code. The Hetzner
  chart's `values.yaml` sets neither `api_addr` nor `cluster_addr`, so **the chart must be injecting them**
  — relevant when that vault is lifted out of Kubernetes.
- **`bao operator unseal -` does not read the key from stdin** in this build. Use the API with the payload
  on stdin, so the key never appears in `argv`:

  ```bash
  printf '{"key":"%s"}' "$KEY" | curl -s -X PUT --data-binary @- http://127.0.0.1:8200/v1/sys/unseal
  ```

- **A fresh server mounts no KV engine** (`-dev` mode does). `secret/` was mounted explicitly:
  `bao secrets enable -path=secret -version=2 kv`.
- **`-format=json` output is pretty-printed** — extracting a key needs a real capture group; `cut -d'"' -f4`
  silently yields garbage. Validate before use: a base64 unseal key decodes to 32 bytes (44 chars *including*
  the `=` pad).
- **`bao token lookup -field=` and `raft snapshot inspect` do not exist here** (the latter is Vault-only), so
  a token is proven by *using* it and a snapshot by *restoring* it.

## Credentials

`bao operator init` wrote `/root/openbao-init-<stamp>.json` (0600). The unseal key and root token are
SOPS-encrypted in `hnatekmarorg/orign` (`bootstrap/secrets/enc.openbao.yaml`) using a **repo-scoped age
key** — not the estate-wide one — so a leak of either key cannot open the other's secrets. The recipient
is declared in that repo's `.sops.yaml`; the private half is **not in any repo**. With 1 share /
1 threshold the risk is *loss*, so keep more than one offline copy.

### Incident: 2026-09-17, the shares leaked into a session transcript

A verification step compared the plaintext against the decrypted file with `diff <(plaintext) <(decrypted)`
while masking only `age1…` recipients. The comparison legitimately mismatched (sops re-serialises YAML
values *unquoted*), and `diff` then printed the **plaintext side**: the unseal key and root token in clear.

Blast radius was small — the vault is loopback-only, unreachable from the network, and held nothing — but the
material was burned. Because the vault was empty, the fix was cheaper than a rebuild: **re-initialise**
(fresh raft state, fresh shares, fresh root token), then rebuild the KV mount, snapshot policy and snapshot
token. Old state was preserved as `data.leaked-<stamp>`, verified, then destroyed; superseded init files
shredded.

**The rule that follows, and it is not optional:**

> Never `diff`, `cat`, or otherwise render a file whose content is secret material. Verify by
> **hash or count** — `sha256sum` of each value, `cmp -s`, or a normalised document hash — and never by
> comparing content you might then have to look at.

Per-key hashing is the right tool: it proves equality, localises a mismatch to a field name, and prints no
values. That is how this incident was actually resolved.


## Restart procedure (automatic)

**A restart seals the vault, and that is now handled without a human.** Three pieces, all on the LXC:

- `openbao-unseal.service` (oneshot) + `/usr/local/bin/openbao-unseal.sh` — idempotent: it reads the
  health endpoint and returns `already unsealed — nothing to do` unless the vault really is sealed. The key
  is read from a root-only file and sent over **stdin**, so it never appears in `argv` or the journal.
- an `ExecStartPost` **drop-in** on the packaged unit (`openbao.service.d/unseal.conf`) — so a restart
  unseals before systemd even considers the start complete. **The `+` prefix is required**: without it the
  command runs as the service user (`openbao`), which cannot read the root-only key, and it fails with
  `no key file` — which is exactly how this was found.
- `openbao-unseal.timer` every 2 minutes as a safety net (covers anything the drop-in misses).

Verified by restarting the vault with the timer *stopped*, so only the drop-in could act: `systemctl
restart` returned with the vault already unsealed and `sealed=true` was never observed.

**The security trade is explicit and accepted:** the unseal key sits in a root-only file on the same host,
so host compromise means vault compromise. It is still narrower than any KMS auto-unseal — no network path,
no API token, no cross-host trust — and it removes the failure mode that actually bites: a reboot leaving
the vault sealed with nothing working until a human notices. Hardening later, in increasing order of
strictness: systemd `LoadCredential`, a Transit/KMS seal so no key rests here, or going back to manual
unseal with the key offline.

Manual unseal, if ever needed as a fallback (key from the operator's offline copy):

```bash
printf '{"key":"%s"}' "$KEY" | curl -s -X PUT --data-binary @- http://127.0.0.1:8200/v1/sys/unseal
curl -s http://127.0.0.1:8200/v1/sys/health     # expect "sealed":false,"standby":false
```

## Snapshots (verified)

Daily via `openbao-snapshot.timer` → `/usr/local/bin/openbao-snapshot.sh`:

- scoped token: policy `openbao-snapshot` grants only `read` on `sys/storage/raft/snapshot`; a periodic
  (720h) orphan token lives in `/etc/openbao/tokens/snapshot` (0600) and renews itself each run
- `bao operator raft snapshot save` → **age-encrypted at the source** → **plain snapshot shredded**
- shipped to `/mnt/backups/openbao/` on the NAS, keeping 30 days there and 14 days locally
- **encrypted at source deliberately**: `/mnt/data/backups` is broadly readable and a snapshot contains the
  entire vault. The shipped file is ciphertext; only the offline age key opens it
- if the export is not mounted the run says so in `/var/log/openbao-snapshot.log` and keeps a local copy —
  it never fails silently

**Restore drill (passed 2026-09-17):** snapshot taken, format confirmed (`state.bin`, `SHA256SUMS`,
`SHA256SUMS.sealed`), restored in place with `bao operator raft snapshot restore -force`, and afterwards the
vault was unsealed with `secret/` mounted, a marker key written *before* the snapshot present, new writes
working, and the snapshot token still able to save. To restore for real: decrypt with the offline age key,
then run the same command against a running, unsealed instance (unseal first if it is fresh).

## Seeding an application secret (worked example: the CSI driver's API key)

A secret reaches a cluster only through its own prefix. `scripts/wire-vault.sh` writes the per-cluster
read policy as `secret/data/<cluster>/*` plus `list` on the metadata path, so **the same value is written
once per cluster that consumes it** — one key per prefix, never one shared path.

Worked example: `secret/dev/truenas-csi`, property `api-key`, read on the cluster side by
`ExternalSecret/truenas-csi-api` through the `local-dev` store (namespace `truenas-csi`).

```bash
# On the vault host (LXC 120). The root token is read locally and never crosses the wire; the value is
# fed over stdin, so it lands in no argv on either side.
ssh root@172.16.40.33
export BAO_ADDR=http://127.0.0.1:8200                        # the listener is loopback-only by design
export BAO_TOKEN=$(python3 -c "import json;print(json.load(open('/root/openbao-init-<stamp>.json'))['root_token'])")
printf '%s' "$API_KEY" | bao kv put secret/dev/truenas-csi api-key=-
bao kv list secret/dev                                       # cloudflare  smoke-test  truenas-csi
```

Verify by **length and hash — never by rendering the value** (the rule from the 2026-09-17 incident above):

```bash
bao kv get -format=json secret/dev/truenas-csi | python3 -c "
import sys, json, hashlib
v = json.load(sys.stdin)['data']['data']['api-key']
print(len(v), hashlib.sha256(v.encode()).hexdigest()[:12])"
```

No vault-side change is needed for the cluster to use it: the store and role already cover the prefix, and
the ExternalSecret names the path *inside* the mount (`dev/truenas-csi`), not the mount itself.

**The key**: appliance API keys are user-linked and expire. This one belongs to the `csi` service user
(Full Admin, expires 2027-09-20); until ESO owns it, a copy lives in
`/root/network-migration/credentials/truenas-csi.env` on the operator host. Rotate by minting a new key,
seeding it, letting ESO refresh (`refreshInterval: 1h`), then revoking the old one on the appliance.

## Still to do

- [x] **Off-host snapshots — working via a hop.** The blocker was *not* the export: it is `*` again, and
      both adonai (a VM) and a mgmt host mount it happily. The LXC is denied on **every** export, which
      makes it client-side: an **unprivileged Proxmox LXC cannot use the kernel NFS client** without
      `features: mount=nfs` in its config. Diagnosis that settled it: mounting several `*` exports, all
      denied, while another host on the same bridge succeeded.
      Until that feature is set (one line, plus a container restart — which leaves the vault sealed), the
      snapshot ships **LXC → adonai → NAS** over a dedicated key. srv→srv, which the firewall matrix already
      permits. Verified: identical sha256 on both ends, ciphertext on the NAS, and no host able to decrypt
      it. The script prefers the direct path automatically once `/mnt/backups` mounts here.
      *Fix if you want the direct path:* `pct set 120 --features mount=nfs` (unprivileged containers need
      it explicit), then unseal afterwards.
- [x] **TLS** — live via Caddy + Cloudflare DNS-01; `api_addr` now the external name. See the TLS section above.
- [x] **Auth** — `kubernetes` live and proven end to end (a secret written to the vault arrives as a Kubernetes Secret in the dev cluster via ESO). `approle` for hosts still to do.
- [ ] **Vault config as code** — `vault.upbound.io` Crossplane manifests in `orign/crossplane/`, once TLS
      exists (every ESO store in the estate speaks `https://`).
- [ ] **Firewall matrix** — srv→srv needs nothing; add an explicit line for **mgmt → vault**
      (personal-hermes consumes it via the `local-hermes` store).
- [ ] **Second copy off-host** — a pull from an mgmt host (mgmt→srv is permitted; srv→mgmt is not) until
      the NAS export works.
