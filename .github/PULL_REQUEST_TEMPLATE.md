<!-- PR Template for devops-cluster -->

## Type of Change
- [ ] Device Change
- [ ] Cluster Change
- [ ] Docs
- [ ] Chart
- [ ] CI

<!-- If Device Change -->
### Device Change Details
- **Module:** `<!-- e.g. terraform/routeros/main.tf -->`
- [ ] Merge authorizes apply.
- **Plan Summary:** `<!-- X to add, Y to change, Z to destroy -->`
- **Expected Result:** `<!-- What should happen? -->`
- **Rollback Plan:** `<!-- How to revert? -->`
- **Change Window:** `<!-- Date/Time -->`

<!-- If Cluster Change -->
### Cluster Change Details
- **Cluster Root:** `<!-- e.g. ./bootstrap/argocd/devops -->`
- [ ] Prerequisites (router reservations and DNS) are applied first.
- **Plan Summary:** `<!-- X to add, Y to change, Z to destroy -->`

<!-- If Docs or Chart -->
### Docs / Chart Change
- `<!-- Describe change briefly -->`

## Verification
- [ ] I fetched `main` before branching. (Stale tree plans destroys)
- [ ] No secret is in the diff.
