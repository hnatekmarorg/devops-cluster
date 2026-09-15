# The CI runner

The seven workflows that touch the estate's devices (plan, both applies, drift) run on a **dedicated
ZimaBoard in the `mgmt` plane**, not on the ARC scale set in the k8s cluster. `opencode.yml` and
`renovate.yml` stay on ARC: they run workloads, not device changes.

## Why it exists

Two problems, one box:

1. **Privilege.** The runners hold the device *write* credentials, so they belong where privilege lives —
   `mgmt` (Q27). The matrix makes `lab → mgmt` a confident deny, which is exactly right and which the
   old arrangement could not survive.
2. **The `ether2` ceiling.** The ARC runners ran on a guest behind balteus's `ether2`, so an apply that
   interrupted that port killed its own runner mid-flight. That is how the #65 apply died with the device
   changed and the state stale. A runner in mgmt removes the coupling — and lets the k8s cluster be
   recreated without taking CI down with it.

## What it is

| | |
|---|---|
| hardware | ZimaBoard, x86_64, one NIC in use (`enp2s0`; `enp3s0` dark) |
| OS | Fedora 44, hostname `runner` |
| port | the router's `ether1` — a mgmt access port (`pvid 10`, admit-only-untagged) |
| address | `172.16.10.140` (reserved in `dhcp.tf`); it showed up on a pool address first |
| name | `runner.mgmt.hnatekmar.dev` |
| labels | `self-hosted, linux, x64, mgmt, tofu` |
| runner | `ghcr.io/actions/actions-runner` in podman, container `github-runner`, restart `always` |
| boot | `podman-restart.service` is enabled, so it comes back after a reboot |

## How it was built, and the one trap

```bash
podman run -d --name github-runner --restart=always \
  -v /srv/runner/_work:/home/runner/_work:Z,U \
  -v /root/.runner_token:/run/secrets/runner_token:ro,Z \
  ghcr.io/actions/actions-runner:latest \
  /bin/bash -c "cd /home/runner && ./config.sh --url https://github.com/hnatekmarorg/devops-cluster \
      --token \"$(cat /run/secrets/runner_token)\" --name runner-mgmt-01 \
      --labels self-hosted,linux,x64,mgmt,tofu --work _work --unattended --replace && exec ./run.sh"
```

**The trap:** the image runs as uid **1001**, so a bind-mounted token file owned by `root` is unreadable
inside the container. `cat` fails, `--token` is empty, and the runner reports *"Invalid configuration
provided for token"* — which reads exactly like an expired token and is not. `chown 1001:1001` +
`chmod 400` before starting, and the registration succeeds. This cost several attempts and two wrong
diagnoses; it is written down so it costs none next time.

**Registration tokens expire in an hour and cannot be minted by the bot** (`403`: needs repository
runners permission, or org admin for the org scope). A fine-grained PAT with *Runners: Read and write*
would allow minting as needed — worth doing if the runner is ever rebuilt.

## Recovering it

- **Container restarted** — nothing to do; restart policy is `always`.
- **Host rebooted** — nothing to do; `podman-restart.service` starts it.
- **Container recreated** — the registration lives in the container's layer (`/home/runner/.runner`,
  `.credentials`), so a recreate needs a **fresh registration token** and the recipe above.
- **Fall back to ARC** — change `runs-on` back to `gha-runner-scale-set-hnatekmarorg` in the four files
  (one line each). That is the whole rollback.
- `cockpit.socket` is **enabled** on the box (that is the listener on `:9090`). A runner needs nothing
  inbound, so disabling it is reasonable if the box is not administered through it.
