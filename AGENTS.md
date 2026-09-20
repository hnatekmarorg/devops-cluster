# AGENTS.md

This repository contains configuration of 2 kubernetes clusters:

- bootstrap cluster that bootstraps all other clusters with help of [CAPI](https://cluster-api.sigs.k8s.io/) (located in ./bootstrap/)
- devops cluster located in ./devops/

All clusters are managed by [argocd](https://argo-cd.readthedocs.io/en/stable/)

There are also supporting helm charts inside ./charts/ check ./charts/README.md for details

## Bootstrapping cluster

Argocd configurations for cluster go in `./bootstrap/argocd/`

### CAPI configs

Cluster basically contains only CAPI configs for example `./bootstrap/argocd/devops/` contains configs for devops cluster

## Devops cluster

Argocd configurations for cluster go in `./devops/argocd/`

### Secrets

Secrets are managed by SOPS operator <https://github.com/isindir/sops-secrets-operator>

- Create folder `./secrets`
- Create yaml manifest with SOPS secret (check <https://github.com/isindir/sops-secrets-operator> for documentation)
- Call `./scripts/encrypt.sh`

### GPU workflows

Dev cluster has nodes with nvidia gpu for it to work you need to have nvidia gpu in resources and you also need toleration:

```
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
```

### Storage

Three tiers, all declared in `charts/cluster-base` (`storage.*` values) so every cluster gets the same
shape and a cluster only records which ones it turns on:

| tier | class | for | configured |
|---|---|---|---|
| cluster-local block | `longhorn` (**default**) | fast RWO, DBs, scratch — no network dependency | `./devops/argocd/` (per cluster) |
| NAS block, RWO | `truenas-nvmeof` | durable volumes for state that must outlive a node | `charts/cluster-base/templates/storage/truenas-csi/` — the official `truenas-csi` driver over NVMe-oF/TCP |
| NAS shared, RWX | `nfs-client` | shared storage between pods | `charts/cluster-base/templates/storage/nfs/nfs-provisioner.yaml` |

- **Use NFS when several pods must share the same data**; use a block class (RWO) for a database or
  anything with a filesystem that must not be shared.
- **The NAS tiers ride the air-gapped 10G island and are addressed by the storage name**
  (`truenas.storage.hnatekmar.dev` = `192.168.88.25`), never the srv one (`172.16.40.148`, 1G). The
  appliance answers NFS/iSCSI/NVMe-oF on the management address too, so the wrong name is a slow-but-
  working data path rather than an error. The **API** URL in contrast is the srv name, because the
  control plane must be reachable from every class.
- **One field cannot take the name:** `storage.truenasCsi.nvmeofPortal` is an IP literal
  (`192.168.88.25:4420`). The driver resolves it to a port on the appliance and creates one if it does
  not match, and `nvmet.port.create` validates an IPv4/IPv6 address — a hostname fails provisioning
  before any volume exists. `nfsServer` may be (and is) the name, because the node resolves that one.
- **The CSI driver's API key comes from the vault**, `secret/<cluster>/truenas-csi` (property `api-key`),
  fetched by ESO — seeding is documented in `terraform/docs/openbao-onprem.md`. Nothing secret goes in
  this repo for it.
- NAS prep that the driver assumes (all outside this repo): the NVMe-oF service running with a TCP port
  on `192.168.88.25:4420`, a parent dataset for volume zvols (`data/nvmeof`, snapshotted daily), and the
  API key's service user.

### Ingress

- For domain always use \*.hnatekmar.dev (for example app1.hnatekmar.dev)
- ALWAYS create tls for ingress
- ALWAYS use `cert-manager.io/cluster-issuer: letsencrypt-cloudflare` annotation

Here is example of ingress:

```
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: silly-tavern
  namespace: silly-tavern
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-cloudflare
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - tavern.hnatekmar.dev
      secretName: tavern-tls
  rules:
    - host: tavern.hnatekmar.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: silly-tavern
                port:
                  number: 8000
```
