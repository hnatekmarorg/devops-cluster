# LibreChat Deployment Guide

## Quick Start

### 1. Keycloak Client (hetzner-k8s)

The Keycloak client has been created at:
`hetzner-k8s/crossplane/config/keycloak/clients/librechat.yaml`

**Actions:**
```bash
cd hetzner-k8s
git add crossplane/config/keycloak/clients/librechat.yaml
git commit -m "feat: Add Keycloak client for LibreChat OIDC"
git push
```

**Wait for:** ArgoCD to sync and create the `librechat-creds` secret in `crossplane-system` namespace.

**Extract credentials:**
```bash
kubectl get secret librechat-creds -n crossplane-system -o jsonpath='{.data.clientSecret}' | base64 -d
```

### 2. Generate LibreChat Credentials

Use the [LibreChat Credentials Generator](https://www.librechat.ai/toolkit/creds_generator) to generate:
- `CREDS_KEY` (32+ char hex)
- `CREDS_IV` (16 char hex)
- `JWT_SECRET`
- `JWT_REFRESH_SECRET`
- `MEILI_MASTER_KEY`

### 3. Configure AI Provider API Keys

Edit `devops-cluster/devops/argocd/librechat/secrets/credentials.yaml`:
- Add your OpenAI API key
- Add your Anthropic API key (optional)
- Add generated credentials

### 4. Encrypt Secrets

```bash
cd devops-cluster
./scripts/encrypt.sh devops/argocd/librechat/secrets/credentials.yaml
```

### 5. Deploy LibreChat

```bash
cd devops-cluster
git add devops/argocd/librechat/
git commit -m "feat: Add LibreChat deployment with external AI endpoints"
git push
```

**Wait for:** ArgoCD to sync the application.

### 6. Verify Deployment

```bash
# Check pod status
kubectl get pods -n librechat

# Check ingress
kubectl get ingress -n librechat

# Check TLS certificate
kubectl get certificates -n librechat

# Test access
curl https://librechat.hnatekmar.dev/api/health
```

### 7. Configure OIDC in LibreChat

After deployment, update the `librechat-config` ConfigMap with Keycloak OIDC settings:

```bash
# Get client secret from Crossplane
CLIENT_SECRET=$(kubectl get secret librechat-creds -n crossplane-system -o jsonpath='{.data.clientSecret}' | base64 -d)

# Update librechat.yaml config (add to values.yaml or create ConfigMap)
```

## Directory Structure

```
hetzner-k8s/
└── crossplane/
    └── config/
        └── keycloak/
            └── clients/
                └── librechat.yaml  # Keycloak client definition

devops-cluster/
└── devops/
    └── argocd/
        └── librechat/
            ├── application.yaml     # ArgoCD Application
            ├── values.yaml          # Helm values overrides
            └── secrets/
                └── credentials.yaml # SOPS encrypted secrets (after encryption)
```

## Configuration Summary

### Storage (NFS with deterministic paths)
- **MongoDB**: `/mnt/data/k8s/clusters/main/librechat-mongodb`
- **Meilisearch**: `/mnt/data/k8s/clusters/main/librechat-meilisearch`
- **Uploads**: `/mnt/data/k8s/clusters/main/librechat-uploads`

### Network
- **Domain**: `librechat.hnatekmar.dev`
- **TLS**: Automatically provisioned via cert-manager
- **Ingress Class**: nginx

### Resources
- **Replicas**: 2-5 (autoscaling)
- **CPU**: 250m-500m per replica
- **Memory**: 512Mi-1Gi per replica
- **Storage**: 35GB total (NFS)

### AI Endpoints
- **OpenAI**: Configurable via API key
- **Anthropic**: Configurable via API key
- Add more custom endpoints in `application.yaml`

## Troubleshooting

### Check ArgoCD Sync Status
```bash
argocd app get librechat -n argocd
```

### View LibreChat Logs
```bash
kubectl logs -n librechat -l app=librechat -f
```

### Check NFS Mounts
```bash
kubectl get pvc -n librechat
kubectl describe pvc -n librechat
```

### Test AI Endpoint Connectivity
```bash
kubectl exec -it -n librechat $(kubectl get pod -n librechat -l app=librechat -o jsonpath='{.items[0].metadata.name}') -- curl -v https://api.openai.com/v1/models
```

## Re-deployment Notes

Due to deterministic NFS paths, re-deployment will:
1. Re-use existing data on NAS
2. Preserve MongoDB, Meilisearch, and upload data
3. Maintain user data and chat history

Simply re-apply the manifests or re-push to Git.
