# State lock

**Status:** Operational. Use this runbook when an apply dies and leaves a lock.

This runbook describes how to clear a stale OpenTofu state lock.

## Preconditions
- The Lock ID from the error message.

## Steps
### 1. Use the automated unlock workflow
1. Go to GitHub Actions.
2. Run the `tf-unlock (a stale state lock)` workflow.
3. Provide the Lock ID from the error message.
4. **NOTE:** An error `412 PreconditionFailed` means the lock object exists in S3.
5. **NOTE:** This is not a MinIO fault.

### 2. Manual unlock via MinIO console
1. Log in to the MinIO console.
2. Open the `tofu-state` bucket.
3. Delete the file `routeros/rb5009.tfstate.tflock`.

## Verification
1. Run `tofu plan`.
2. Confirm the lock is gone.

## Rollback
- Not applicable.

## Related documents
- `terraform/docs/agent/ci-runner.md`
