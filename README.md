# Kubernetes infrastructure as code

This repository declares the estate clusters, the network devices, and the supporting Helm charts. ArgoCD converges the clusters.

## Repository layout

| Directory | Description |
| :--- | :--- |
| `bootstrap/` | ArgoCD Application manifests bootstrap the clusters. They include `bootstrap/argocd/dev`, `bootstrap/argocd/prod`, `bootstrap/argocd/devops`, and `bootstrap/init.yaml`. |
| `charts/` | Supporting Helm charts including `cluster-base`, `truenas-csi`, `vllm-proxy`, `llama-cpp`, `thingsboard`, and `crossplane-providers`. |
| `devops/` | GitOps for the devops cluster. It includes `devops/argocd/` and `devops/crossplane/`. |
| `manual/` | A manual ArgoCD values override. |
| `scripts/` | Lifecycle and secret scripts including `tofu-ci.sh`, `bootstrap-cluster.sh`, `teardown-cluster.sh`, `wire-vault.sh`, `kubeconfig.sh`, `tf-plan-check.sh`, `encrypt.sh`, `decrypt.sh`, and `matrix-order-check.py`. |
| `spike/` | Throwaway experiments including `spike/capmox-talos`. |
| `terraform/` | Network device modules, cluster factory, and cluster roots. See `terraform/README.md` and `terraform/docs/human/README.md`. |
| `.github/` | Workflows, CODEOWNERS, and PR and issue templates. |
| `AGENTS.md` | Instructions for AI agents that work in this repository. |

## Where to start

- For the network and the estate, see `terraform/docs/human/infra-map.md`.
- For the Terraform delivery model, see `terraform/README.md`.
- For a manual task, see `terraform/docs/human/runbooks/README.md`.
- For the measured working notes, see `terraform/docs/agent/`.

## Change model

A plan on the pull request is the review artifact. A merge is the authorization to apply the change. Device and cluster workflows are unarmed until the repository variable is set. The variables are `ROUTEROS_CI_ENABLED` and `CLUSTER_CI_ENABLED`. The pull request templates enforce the plan summary and the rollback.

## Secrets

SOPS encrypts Kubernetes secrets. These secrets live in `devops/argocd/secrets/`. The scripts `scripts/encrypt.sh` and `scripts/decrypt.sh` operate on these secrets. No secret goes into the repository in clear text.

## Dependencies

Renovate keeps dependencies current. The configuration is in `.github/renovate.json`.
