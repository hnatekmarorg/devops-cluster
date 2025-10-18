# AGENTS.md

This repository contains configuration of 2 kubernetes clusters:

- bootstrap cluster that bootstraps all other clusters with help of [CAPI](https://cluster-api.sigs.k8s.io/) (located in ./bootstrap/)
- devops cluster located in ./devops/

All clusters are managed by [argocd](https://argo-cd.readthedocs.io/en/stable/)

There are also supporting helm charts inside ./charts/

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

For storage there are two storageclasses ./devops/argocd/nfs/nfs-provisioner.yaml and longhorn

- Use NFS when you need shared storage between multiple pods
- Use longhorn (default storageclass) for fast storage (DBs, etc...)

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
