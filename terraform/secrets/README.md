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

