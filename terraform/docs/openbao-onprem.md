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


## Restart procedure (important)

**Any restart leaves it sealed.** After a reboot or unit restart:

```bash
BAO_ADDR=http://127.0.0.1:8200 bao status | grep -E "Sealed|Initialized"   # expect Sealed true
# unseal with the operator's offline copy, via the API route above
curl -s http://127.0.0.1:8200/v1/sys/health    # expect "sealed":false,"standby":false
```

## TLS (live)

`https://bao.srv.hnatekmar.dev` serves the vault with a real Let's Encrypt certificate, issued over
**DNS-01** — so the name needs no public A record and stays internal (two labels under the apex, which
`*.hnatekmar.dev` cannot match).

- **Caddy** (build with `github.com/caddy-dns/cloudflare`, from the Caddy download API so no Go toolchain
  is needed) runs on the LXC, terminates TLS, and proxies to the vault on `127.0.0.1:8200`. The vault
  itself never leaves loopback.
- **Cloudflare token** at `/root/.cloudflare-token` (0600, dotenv style: `CLOUDFLARE_TOKEN`,
  `CLOUDFLARE_ACCOUNT_ID`), consumed by the systemd unit via `EnvironmentFile` and referenced in the
  Caddyfile as `{env.CLOUDFLARE_TOKEN}` — the plugin's own expected name (`CLOUDFLARE_API_TOKEN`) is
  deliberately not what the file defines.
- **Token scope**: `Zone → DNS → Edit` + `Zone → Zone → Read`, zone-scoped to `hnatekmar.dev`. That is the
  floor for DNS-01. It is an *account-owned* token, so `/user/tokens/verify` answers `Invalid API Token`
  while the token works perfectly — judge it by reading the zone, not by that endpoint.
- **Vault addresses**: `api_addr = "https://bao.srv.hnatekmar.dev"` (so proxy-terminated TLS and any
  redirects agree) and `cluster_addr = "https://127.0.0.1:8201"` — the latter is honest about being a
  single-node raft; expose 8201 (through Caddy or directly) *before* adding a second node.

**A restart leaves it sealed** — now confirmed in practice, not just in theory. Unseal with the key from the
init file, via the API route above. Which raises the still-open question of *who* owns that key.

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
- [ ] **Auth** — `approle` for hosts, `kubernetes` for the home clusters, policies scoped per path.
- [ ] **Vault config as code** — `vault.upbound.io` Crossplane manifests in `orign/crossplane/`, once TLS
      exists (every ESO store in the estate speaks `https://`).
- [ ] **Firewall matrix** — srv→srv needs nothing; add an explicit line for **mgmt → vault**
      (personal-hermes consumes it via the `local-hermes` store).
- [ ] **Second copy off-host** — a pull from an mgmt host (mgmt→srv is permitted; srv→mgmt is not) until
      the NAS export works.
