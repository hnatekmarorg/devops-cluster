# Runbook 1 — `adonai`: the k3s management VM in `srv`

**State: provisioned, verified, and its address claimed.** Nothing in this runbook is outstanding — go to
runbook 2.

## As built

| | |
|---|---|
| name | **`adonai`** — `adonai.srv.hnatekmar.dev` |
| VMID / host | `144` on balteus |
| class | **srv** (`tag=40`) — where your own migration runbook puts the cluster nodes |
| address | `172.16.40.24` — **reserved** (MAC `bc:24:11:97:1e:1c`); it landed here from the srv pool and keeps it, so nothing ever has to learn a new number |
| OS | Fedora Linux 44 (Server Edition) |
| k3s | `v1.36.4+k3s1`, **stock install** — so Traefik is the ingress controller and ServiceLB holds 80/443 |
| node name | `adonai` (registered as `localhost.localdomain` until the hostname was set; the stale node object was deleted) |
| API | `6443` open to `172.16.0.0/20`; cert SANs include `adonai` and `adonai.srv.hnatekmar.dev` |

## What was changed to get here

```yaml
# /etc/rancher/k3s/config.yaml
tls-san:
  - adonai.srv.hnatekmar.dev
node-name: adonai
```

```bash
hostnamectl set-hostname adonai
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=172.16.0.0/20 port port=6443 protocol=tcp accept'
firewall-cmd --reload
systemctl restart k3s
```

`node-name` is set explicitly rather than relying on the hostname: the first boot had already registered a
node called `localhost.localdomain`, and a cluster whose API is reached by name should not have a node by a
different one.

## Verified (2026-09-16)

- **The Fedora traps did not bite.** SELinux `Enforcing` with `k3s-selinux` installed and the policy module
  loaded, zero AVC denials; and the firewalld/CNI canary **passes** — a pod resolves
  `kubernetes.default.svc.cluster.local`, so flannel traffic is not being eaten while Traefik's 80/443 stays
  open. `cni0`/`flannel.1` are not in a trusted zone and did not need to be.
- Resolver is `172.16.40.1` — the router, i.e. internal names resolve here as they do everywhere else.
- Registry access works (a `busybox:1.36` pull took 3.2s). Worth knowing before the spike pulls CAPI and
  provider images.
- Name-based API access verified from the mgmt host against the cluster CA:
  `curl --cacert server-ca.crt --resolve adonai.srv.hnatekmar.dev:6443:172.16.40.24 https://adonai.srv.hnatekmar.dev:6443/version`
  returns `401 Unauthorized` — TLS validated for the name, credentials simply not sent.

**Canary note for the next person:** `nslookup kubernetes.default` returns `NXDOMAIN`, and that is correct —
that name does not exist. Ask for `kubernetes.default.svc.cluster.local`. The first version of this runbook
used the short form and produced a false alarm.

## Still a decision, not a task

k3s installed with defaults means **Traefik is the ingress controller on this node**. Leave it while this is
a spike. When the estate's ingress decision lands, disabling it is `disable: [traefik]` in the same
`config.yaml` plus a restart, and then ingress-nginx goes in (the devops cluster's choice — one ingress
controller per estate, not two).
