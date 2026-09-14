# `terraform/secrets/` — CI credential material

| File | Committed? | What |
|---|---|---|
| `routeros-ci.env.template` | yes | The shape of the credential file + the exact sops command |
| `routeros-ci.env` | **no** (gitignored, mode 600) | The plaintext source of truth — stays on the box that encrypts it |
| `enc.routeros-ci.env` | yes | The sops-encrypted file the workflow decrypts |

The committed `enc.routeros-ci.env` currently holds **placeholder values**
(`CHANGE_ME_*`), encrypted to the estate age recipient. That is deliberate: it
makes the repository shape final and the decrypt path end-to-end testable, while
the credentials themselves stay out of git. Replace it in one command (see the
template) when the RouterOS users and the state store exist.

This flow is **path (b)** in [`../README.md`](../README.md). Path (a) — a cluster
Secret mounted into the runner pod, no age key in the pod — is preferred and
needs nothing in this directory.

## The state key's MinIO policy

`minio-tofu-state-policy.json` is the policy the CI access key needs — no more.
It is here rather than in the MinIO console so that the permission set is
reviewable and reproducible; when MinIO itself becomes IaC-managed, this file
becomes the resource's `policy` field (until then it is a documented bootstrap
step, per the review rules).

| Statement | Actions | Why exactly these |
|---|---|---|
| `StateBucketMetadata` | `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetBucketVersioning` | `HeadBucket` on `init` needs `ListBucket`; the SDK asks for the bucket location, and versioning is read so the backend's own state-safety check can see it |
| `StateObjectsReadWrite` | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` | read/refresh state, write it on `apply`, and write/release the `*.tflock` lock object that `use_lockfile` puts next to the state. Multipart actions are for state files large enough to upload in parts |

Deliberately **absent**: any DynamoDB permission (locking lives in the bucket,
which is what Q8 chose), `sts:*` and `iam:*` (both validation calls are skipped in
the backend config — MinIO implements neither), and `s3:ListAllMyBuckets`
(nothing lists buckets).

Scope: the whole **`tofu-state`** bucket. That bucket exists only for OpenTofu
state, so this is already narrow, and it keeps a second module (`crs326/`,
`cloudflare/`) from needing a new key. If you prefer device-level scoping
instead, narrow the second resource to
`arn:aws:s3:::tofu-state/routeros/*` — the lock file sits in the same prefix.

### Verified against the live key (2026-09-14)

Not the policy text — the behaviour of the key as MinIO actually enforces it:

| Operation | Result | Reading |
|---|---|---|
| `HeadBucket tofu-state` (`tofu init` does this) | allowed | init succeeds |
| `ListObjectsV2 tofu-state` | allowed | state listing/workspace handling |
| `PutObject` + `DeleteObject` in `tofu-state` | allowed | the `*.tflock` lock write and its release |
| `ListObjectsV2` on `docker-cache` | **denied** (`AccessDenied`) | no cross-bucket reads |
| `PutObject` on `docker-cache` | **denied** (`AccessDenied`) | no cross-bucket writes |
| `ListBuckets` | allowed, returns **`['tofu-state']` only** | MinIO filters this call to the buckets the credential may use, so it is not a widening — it is a second confirmation of the scoping |

`tofu init` + `tofu plan` were then run through `scripts/tofu-ci.sh` against this
bucket over the public break-glass endpoint: both succeeded, and `plan` acquired
and released the lock object, which is what exercises the put/delete pair above.

### Trap: the region name needs validation skipped

MinIO advertises `x-amz-bucket-region: europe`, and the AWS SDK rejects `europe`
**client-side** before any request is sent (`invalid AWS Region: europe`). The
backend therefore passes `skip_region_validation=true` alongside the other skips —
without it, signing with the region MinIO actually advertises is impossible, and
signing with a made-up AWS region means the one value that cannot be wrong is the
one you are not using. (Measured: the estate's registry cache signs `us-east-1`
against the same MinIO and works, because SigV4 verifies with whatever region the
client put in the credential scope — but the backend's *own* region validation
still has to pass first.)


