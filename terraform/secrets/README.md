# `terraform/secrets/` — CI credential material and the state key's policy

| File | Committed? | What |
|---|---|---|
| `routeros-ci.env.template` | yes | the shape of the credential file + the exact sops command |
| `routeros-ci.env` | **no** — gitignored, mode 600 | plaintext source of truth; stays on the box that encrypts it |
| `minio-tofu-state-policy.json` | yes | the policy the CI state key needs — no more |

`sops` delivery (the `enc.*` path) is **supported but unused today**: the role-scoped GitHub
secrets in [`../README.md`](../README.md) are the delivery path in use. A placeholder
`enc.routeros-ci.env` lived here until 2026-09-14 and was deleted — a file that looks like a
credential but holds `CHANGE_ME_*` is worse than no file, because a reviewer cannot tell
placeholder from value.

## The state key's policy

`minio-tofu-state-policy.json` is written as a file rather than clicked into the MinIO console so
the permission set is reviewable and reproducible; when MinIO becomes IaC-managed it becomes the
resource's `policy`.

| Statement | Actions | Why exactly these |
|---|---|---|
| `StateBucketMetadata` | `s3:ListBucket`, `GetBucketLocation`, `GetBucketVersioning` | `init`'s `HeadBucket` needs `ListBucket`; the SDK asks for the location; versioning is read so the backend's own state-safety check can see it |
| `StateObjectsReadWrite` | `s3:GetObject`, `PutObject`, `DeleteObject`, `AbortMultipartUpload`, `ListMultipartUploadParts` | read/refresh state, write on apply, and write/release the `*.tflock` lock object `use_lockfile` keeps beside the state |

Deliberately **absent**: DynamoDB (locking lives in the bucket — Q8), `sts:*`/`iam:*` (both
validation calls are skipped; MinIO implements neither), and `s3:ListAllMyBuckets` (nothing lists
buckets). Scope: the whole `tofu-state` bucket, which exists only for OpenTofu state — that also
spares the next module a new key. Device-level scoping instead would be
`arn:aws:s3:::tofu-state/routeros/*`; the lock file sits in the same prefix.

### Verified behaviour of the live key (2026-09-14)

Not the policy text — what MinIO actually enforces:

| Operation | Result |
|---|---|
| `HeadBucket tofu-state` (`init` does this) | allowed |
| `ListObjectsV2` / `PutObject` / `DeleteObject` in `tofu-state` | allowed — this is the lock write and release |
| `ListObjectsV2` / `PutObject` on `docker-cache` | **denied** (`AccessDenied`) — no cross-bucket access |
| `ListBuckets` | allowed, returns `['tofu-state']` only — MinIO filters it to what the key may use, so it confirms the scoping rather than widening it |

`init` + `plan` then ran end-to-end through `scripts/tofu-ci.sh` against this bucket: both
succeeded and `plan` acquired and released the lock object.

### Trap: MinIO's region name needs validation skipped

MinIO advertises `x-amz-bucket-region: europe`, and the AWS SDK rejects `europe` **client-side**
before any request is sent (`invalid AWS Region: europe`). The backend therefore sets
`skip_region_validation=true` alongside its other skips. Signing with a real AWS region name would
mean signing with the one value MinIO does not advertise.
