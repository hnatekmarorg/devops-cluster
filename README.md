# Kubernetes Infrastructure as Code

This repository contains infrastructure-as-code (IaC) configurations for deploying and managing a Kubernetes cluster using **ArgoCD**, **Crossplane**, **SOPS**, and **Helm**. It is designed to automate the provisioning of control planes, node groups, storage, networking, and application services.

---

## 📁 Directory Structure

- **`.gitignore`**: Excludes sensitive files and IDE artifacts.
- **`bootstrap/argocd/devops/`**: Contains ArgoCD Application manifests for cluster components (control plane, CPU/GPU nodes, etc.).
- **`charts/minio-crossplane/`**: Helm charts for deploying MinIO object storage via Crossplane.
- **`devops/argocd/`**: ArgoCD Application manifests for services like Prometheus, Rook, MetalLB, and secrets.
- **`manual/argocd/`**: Manual overrides for cluster-specific configurations.
- **`scripts/`**: Shell scripts for SOPS encryption/decryption and key initialization.
- **`scripts/decrypt.sh` / `scripts/encrypt.sh`**: Automate secret management with SOPS.
- **`scripts/init-key.sh`**: Initializes the SOPS age key secret in Kubernetes.

---

## 🛠️ Getting Started

1. **Prerequisites**
   - `kubectl`
   - `argo` CLI
   - `sops` (for secret management)
   - `helm` (for Crossplane/MinIO)

2. **Initialize the Cluster**
   ```bash
   # Initialize SOPS key
   ./scripts/init-key.sh

   # Decrypt secrets (if needed)
   ./scripts/decrypt.sh

   # Apply ArgoCD Applications
   kubectl apply -f bootstrap/init.yaml
   ```

3. **Verify Deployment**
   ```bash
   kubectl get applications -n argocd
   ```

---

## 🔐 Secret Management

- Secrets are encrypted using **SOPS** and stored in `devops/argocd/secrets/enc.*.yaml`.
- Decryption is handled by `scripts/decrypt.sh`, which uses the age key mounted at `/etc/sops-age-key-file`.

---

## 📌 Notes

- Replace placeholder values in `charts/minio-crossplane/values.yaml` with your actual MinIO endpoint and credentials.
- Ensure the control plane IP in `bootstrap/argocd/devops/main.yaml` matches your environment.
- GPU/CPU node groups are defined in `bootstrap/argocd/devops/gpu.yaml` and `bootstrap/argocd/devops/cpu.yaml`.

---

## 🧩 Contributing

- Add new ArgoCD Applications to `devops/argocd/`.
- Add new Helm charts to `charts/`.
- Add manual overrides to `manual/argocd/` if needed.
- Always encrypt secrets before committing.
