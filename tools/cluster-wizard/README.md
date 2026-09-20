# cluster-wizard

A small Bubble Tea / [huh](https://github.com/charmbracelet/huh) wizard that generates the boilerplate
for the **two pull requests** that stand up a new cluster. It replaces hand-copying `terraform/clusters/dev`
and pasting reservation entries into the router root.

Run it from anywhere inside the repo:

```bash
cd tools/cluster-wizard
go run .
```

It refuses to start unless the working tree is clean, then writes two **stacked** branches and commits
them — it never pushes and never opens a PR:

| Branch | Contents |
|---|---|
| `feat/<name>-router-prereqs` | `terraform/routeros/dhcp.tf` reservations, `terraform/routeros/dns.tf` records, and (optionally) the cluster's service wildcard |
| `feat/<name>-cluster-root` | `terraform/clusters/<name>/{versions,providers,backend,main}.tf` and `bootstrap/argocd/<name>/cluster-base.yaml` |

## Order matters

1. Merge and **apply** the router PR first. A node with no reservation still gets a ten-minute pool lease,
   so the cluster comes up looking fine and then re-addresses itself.
2. Merge the cluster PR. CI derives `cluster-<name>/terraform.tfstate` from the directory name, so no
   workflow change is needed.

See [`terraform/docs/cluster-lifecycle.md`](../../terraform/docs/cluster-lifecycle.md) for the full flow.

## Insertion contract

The tool inserts into the router locals maps at two sentinel comments that must keep existing:

- `terraform/routeros/dhcp.tf`: `# cluster-wizard:insert-reservations`
- `terraform/routeros/dns.tf`: `# cluster-wizard:insert-dns-records`

It aborts rather than guessing if either is missing, if the cluster directory already exists, or if a
new node's address or MAC is already reserved.

## Flags

| Flag | Meaning |
|---|---|
| `--config FILE` | load the whole config from JSON and skip the forms (`--dry-run` uses this) |
| `--dry-run` | render everything to stdout; write nothing, run no git |
| `--no-wildcard` | skip the cluster service-wildcard record |
| `--base BRANCH` | branch the first PR is cut from (default `main`) |

```bash
go run . --config /tmp/staging.json --dry-run
```

Generated HCL is `tofu fmt`-clean, which CI enforces (`tofu fmt -check -recursive`).
