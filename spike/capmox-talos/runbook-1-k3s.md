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

- SELinux: `Enforcing`, `k3s-selinux` installed, policy module loaded, zero AVC denials. That trap is
  genuinely absent here.
- **firewalld: the cheap canary passed, and the trap bit anyway — hours later, somewhere else.** A pod
  *does* resolve `kubernetes.default.svc.cluster.local` with `cni0`/`flannel.1` outside a trusted zone, so
  the DNS test says fine. What that test hides is pod → *node* traffic: `metrics-server` could not reach
  the kubelet —

  ```
  Failed to scrape node err="Get \"https://172.16.40.24:10250/metrics/resource\": dial tcp ..."
  Failed probe metric-storage-ready err="no metrics to serve"
  ```

  — so it never became ready, so `v1beta1.metrics.k8s.io` sat **`False (MissingEndpoints)` from boot**, and
  an unavailable aggregated API fails *discovery* — which blocks **namespace finalization cluster-wide**.
  It surfaced as `clusterctl init` hanging forever on its cert-manager verification: the test namespace it
  creates could not be deleted. Fixed with the k3s-recommended posture:

  ```bash
  firewall-cmd --permanent --zone=trusted --add-interface=cni0
  firewall-cmd --permanent --zone=trusted --add-interface=flannel.1
  firewall-cmd --reload     # metrics-server then goes 1/1, and the APIService turns True
  ```

  Lesson worth keeping: **a passing pod-DNS canary does not clear firewalld.** Check
  `kubectl get apiservice` (every entry `True`) and `kubectl -n kube-system get pods | grep metrics-server`
  (`1/1`). An unhealthy aggregated API is not cosmetic — it fails discovery, and discovery failure blocks
  namespace deletion, which is how it reached something as unrelated as `clusterctl`.
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
