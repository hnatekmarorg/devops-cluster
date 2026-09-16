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

## Resolved 2026-09-16: the routeros API login from this runner

The fault that split the device workflows across two runners is fixed, and **every workflow that touches
a device now runs here** — plan, drift and both applies.

`tofu plan` against the RB5009 used to fail here with:

```
Error: could not login: EOF; close %!w(<nil>)
```

**What it was.** The router's `api` service carried
`available-from=172.16.100.0/24,172.16.101.0/24` — the compat subnet, plus the vestigial work subnet
that has carried no link since that experiment (`docs/network-wiring.md`). RouterOS completes the TCP
handshake and then closes the connection for a source outside that list, and **writes nothing to the
log**. The runner sits in mgmt (`172.16.10.202`), outside the list; the ARC runners were in compat
(`172.16.100.146`), inside it — which is why the same workflow, credential and destination worked on ARC
and not here. The CRS326 carries no such filter, which is what made it read as device-specific.

**Why it stayed invisible for a day.** The setting lived only on the device: nothing in this repository
knew it existed, so no plan showed it and no review could catch it — it broke the moment the runner left
the subnets the filter named. It is now declared in **`terraform/routeros/services.tf`** (mirrored for the
switch in `terraform/crs326/services.tf`), so the next move shows up as a diff instead of as a mystery.

**How it was found** — kept because it is the shape of "the device is fine, the client is fine, and the
two cannot talk":

- the runner's host reached `8728` at TCP level on both the compat and the mgmt address, and a container
  on the same image did too — so not NAT, not reachability, not the destination address;
- the router's users (`admin`, `agent-ro`, `iac`) all read `address=""`, and the *services* were believed
  to read `address=(any)` — that reading is what hid the answer; the allow-list was in `available-from`
  on the service itself;
- the CRS326 accepted the identical login from the same runner and logged it
  (`user agent-ro logged in from 172.16.10.202 via api`), while the RB5009 logged nothing at all;
- the input chain was exonerated by counters (`/ip firewall filter print stats where chain=input` before
  and after an attempt: no delta, no drop for that source);
- the decisive step was a one-line read on the router — `/ip service print detail where name="api"` —
  plus a bogus login from a mgmt host, which reproduced the reset instantly (`ConnectionResetError`,
  where the CRS326 answers the same probe with `!trap invalid user name or password`).

The lesson worth keeping: **a setting the control path depends on has to live in the repository.**
"Device-specific, unsolved, not urgent" described the symptom correctly and was the wrong place to rest —
the answer was one `print detail` away, on an object the earlier pass had read from the wrong side.

## Recovering it

- **Container restarted** — nothing to do; restart policy is `always`.
- **Host rebooted** — nothing to do; `podman-restart.service` starts it.
- **Container recreated** — the registration lives in the container's layer (`/home/runner/.runner`,
  `.credentials`), so a recreate needs a **fresh registration token** and the recipe above.
- **Fall back to ARC** — change `runs-on` back to `gha-runner-scale-set-hnatekmarorg` in the four files
  (one line each). That is the whole rollback.
- `cockpit.socket` is **enabled** on the box (that is the listener on `:9090`). A runner needs nothing
  inbound, so disabling it is reasonable if the box is not administered through it.
