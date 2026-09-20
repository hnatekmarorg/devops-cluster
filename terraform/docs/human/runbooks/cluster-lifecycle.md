# Cluster lifecycle

**Status:** Operational. Use this runbook to create or to destroy a cluster.

This runbook describes the creation and destruction of Kubernetes clusters. Use it to provision new clusters or tear down existing clusters.

## Preconditions
- The following CI preconditions must be met:

| Requirement | Location | Purpose |
|---|---|---|
| `CLUSTER_CI_ENABLED=true` | Repository variable | Enable infrastructure changes on merge |
| `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` | Repository secrets | Read-only identity for plan generation |
| `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` | `clusters-production` environment | Write identity for cluster allocation |
| `TF_STATE_BUCKET`, `TF_STATE_ENDPOINT`, `TF_STATE_REGION` | Repository variables | S3 state storage |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Repository secrets | State bucket access |
| `@Hnatekmar` satisfies CODEOWNERS | Repository | Mandatory review for terraform and bootstrap |

- A prerequisites PR for router reservations and DNS must be applied.

## Steps
### 1. Provision Cluster
1. Create a cluster root in `terraform/clusters/<name>/` with these files:
    - `versions.tf`
    - `providers.tf`
    - `backend.tf`
    - `main.tf`
2. Create `bootstrap/argocd/<name>/cluster-base.yaml`.
3. Merge the PR.

To provision manually, run these commands:

```bash
cd terraform/clusters/<name>
TF_STATE_KEY=cluster-<name>/terraform.tfstate ../../../scripts/tofu-ci.sh --role=none init -input=false
TF_STATE_KEY=cluster-<name>/terraform.tfstate ../../../scripts/tofu-ci.sh --role=none apply
./scripts/bootstrap-cluster.sh <name>
./scripts/wire-vault.sh <name>
./scripts/kubeconfig.sh <name>
```

### 2. Configure SSO Kubeconfig
The kubeconfig contains no credentials. 
1. Install the `kubelogin` plugin.
2. Point `KUBECONFIG` to `terraform/clusters/<name>/kubeconfig.yaml`.
3. Run a `kubectl` command to open the browser for authentication.

### 3. Destroy Cluster
1. Merge a PR that deletes the cluster root.
2. To destroy manually, run this command:
```bash
./scripts/teardown-cluster.sh <name>
```

**NOTE:** `teardown-cluster.sh` drains Karpenter claims, runs tofu destroy, sweeps orphan VMs, and can unmount vault using `--unmount-vault`.

## Verification
- Verify node status with `kubectl get nodes`.
- Verify access with `kubectl auth can-i get pods`.

## Rollback
Run the destroy procedure to remove failed provisioning attempts.

## Related documents
- `terraform/docs/agent/cluster-lifecycle.md`
