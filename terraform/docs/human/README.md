# Human Documentation Index

This directory provides a readable layer of documentation for the infrastructure. It uses ASD-STE100 Simplified Technical English.

## Documentation Layers

This repository uses two layers of documentation:
1. **Human Layer (`human/`)**: This layer is for humans. It is easy to read.
2. **Agent Layer (`agent/`)**: This layer holds raw measurements and reasoning. Agents wrote these notes.

## Infrastructure Guides

- [`infra-map.md`](infra-map.md): The high-level map of the infrastructure.
- [`network-schema.md`](network-schema.md): The logical design of the network.
- [`ssh-config`](ssh-config): The configuration for SSH access.
- [`runbooks/README.md`](runbooks/README.md): The index of operational runbooks.

## How to use these documents

Follow this order to understand the system:
1. Read the [`infra-map.md`](infra-map.md) first.
2. Read the [`network-schema.md`](network-schema.md) second.
3. Read the runbook in [`runbooks/README.md`](runbooks/README.md) for your specific task.

## Operational Runbooks

| Runbook | Status |
|---|---|
| `balteus-vlan` | Outstanding. |
| `ci-runner` | Operational. The runner is built. Use this runbook for recovery. |
| `cluster-lifecycle` | Operational. Use this runbook to create or to destroy a cluster. |
| `compat-retirement` | Outstanding. Do this after the last device leaves the compat segment. |
| `crs326-adoption` | The switch side is applied. The CRS317 side is hand-applied and outstanding. |
| `crs804-mgmt` | Outstanding. Do this last of the switches, after charon is in mgmt. |
| `css610-cutover` | Outstanding. This is the first window in which devices move. |
| `openbao` | Operational. The vault is working. Use this runbook for restarts, snapshots and seeding. |
| `router-bootstrap` | Partly outstanding. Check the list in the agent source before you start. |
| `state-lock` | Operational. Use this runbook when an apply dies and leaves a lock. |
| `talos-template` | Operational. Use this runbook when you must rebuild the Proxmox template. |
| `wan-move` | Applied and verified 2026-09-14. Use this runbook to verify the state or to recover. |
