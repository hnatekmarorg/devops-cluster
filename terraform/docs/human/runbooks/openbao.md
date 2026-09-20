# OpenBao

**Status:** Operational. The vault is working. Use this runbook for restarts, snapshots and seeding.

This runbook describes the operation of the on-prem OpenBao instance. Use it to restart, unseal, snapshot, restore, or seed secrets.

## Preconditions
- SSH access to `root@172.16.40.33`.
- Access to the offline age key for decryption.

## Steps
### 1. Host Facts
The service runs on LXC 120 on balteus at `172.16.40.33`. It uses OpenBao 2.6.2 with raft storage and a loopback listener.

### 2. Restart and Unseal
The system uses an automatic unseal service. If the vault is sealed, use this manual command:

```bash
printf '{"key":"%s"}' "$KEY" | curl -s -X PUT --data-binary @- http://127.0.0.1:8200/v1/sys/unseal
```

Verify the status:

```bash
curl -s http://127.0.0.1:8200/v1/sys/health
```

### 3. Snapshot and Restore
A timer performs daily snapshots. To restore a snapshot, decrypt the file with the offline age key. Then run this command on a running, unsealed instance:

```bash
bao operator raft snapshot restore -force
```

### 4. Seed Application Secret
1. SSH to the host: `ssh root@172.16.40.33`.
2. Set the environment variables:
```bash
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(python3 -c "import json;print(json.load(open('/root/openbao-init-<stamp>.json'))['root_token'])")
```
3. Put the secret:
```bash
printf '%s' "$API_KEY" | bao kv put secret/dev/truenas-csi api-key=-
```

## Verification
**WARNING:** Never `diff`, `cat`, or render secret material. Verify secret material by hash or count.

Verify the secret by length and hash:

```bash
bao kv get -format=json secret/dev/truenas-csi | python3 -c "
import sys, json, hashlib
v = json.load(sys.stdin)['data']['data']['api-key']
print(len(v), hashlib.sha256(v.encode()).hexdigest()[:12])"
```

## Rollback
Restore the vault from the latest daily snapshot.

## Related documents
- `terraform/docs/agent/openbao-onprem.md`
