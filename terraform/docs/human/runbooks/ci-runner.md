# CI runner

**Status:** Operational. The runner is built. Use this runbook for recovery.

This runbook describes how to build and recover the ZimaBoard runner and restore dead broker sessions.

## Preconditions
- SSH access to the runner host at `172.16.10.140`.
- A valid registration token for GitHub Actions.

## Steps
### 1. Build or recover the runner
1. Create the token file at `/root/.runner_token`.
2. **WARNING:** Change the owner to `1001:1001`.
3. **WARNING:** Set the permissions to `400`.
4. **NOTE:** The image runs as uid 1001. Root-owned tokens fail.
5. Run the following command:
```bash
podman run -d --name github-runner --restart=always \
  -v /srv/runner/_work:/home/runner/_work:Z,U \
  -v /root/.runner_token:/run/secrets/runner_token:ro,Z \
  ghcr.io/actions/actions-runner:latest \
  /bin/bash -c "cd /home/runner && ./config.sh --url https://github.com/hnatekmarorg/devops-cluster \
      --token \"$(cat /run/secrets/runner_token)\" --name runner-mgmt-01 \
      --labels self-hosted,linux,x64,mgmt,tofu --work _work --unattended --replace && exec ./run.sh"
```

### 2. Recover a dead broker session
1. Check if the container is running:
```bash
podman ps
```
2. Check the logs for broker errors:
```bash
podman logs --tail 40 github-runner
```
3. Verify DNS resolution for the broker:
```bash
podman exec github-runner getent hosts broker.actions.githubusercontent.com
```
4. Verify connectivity to the broker:
```bash
podman exec github-runner curl -sS -o /dev/null -w '%{http_code}\n' \
  https://broker.actions.githubusercontent.com/
```
5. **NOTE:** A return code of `404` is the healthy answer.
6. Restart the container:
```bash
podman restart github-runner
```

### 3. Recover a hanging job
1. Check for stuck processes:
```bash
podman exec github-runner ps -eo pid,etimes,time,pcpu,stat,cmd --sort=-etimes | head
```
2. Check the job output for silence:
```bash
podman logs --tail 50 github-runner
```
3. **CAUTION:** Tofu has no client-side timeout. A stale connection can hang a runner.
4. Attempt recovery in this order:
    - Restart the container.
    - Reboot the host.
    - Recreate the container.
    - Fall back to ARC runners.

### 4. Job Bounds
1. Use `timeout-minutes` on every device job.
2. Set 15 minutes for plans.
3. Set 20 minutes for drift and apply.
4. Use `-lock=false` for plan and drift workflows.
5. Set `cancel-in-progress: true` for plan and drift workflows.
6. **NOTE:** Applies must keep locking and `cancel-in-progress: false`.

## Verification
1. Confirm the runner status is "Online" in the GitHub repository settings.
2. Verify that queued jobs start executing.

## Rollback
1. Change `runs-on` to `gha-runner-scale-set-hnatekmarorg` in the four workflow files.

## Related documents
- `terraform/docs/agent/ci-runner.md`
- `terraform/docs/agent/cluster-lifecycle.md`
