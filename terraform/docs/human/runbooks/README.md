# Operational Runbooks

This folder contains step-by-step guides for manual tasks.

## Network Migration
- [`wan-move`](wan-move.md) — **Status:** Applied and verified 2026-09-14. Use this runbook to verify the state or to recover. — Move the PPPoE client to a dedicated port.
- [`crs326-adoption`](crs326-adoption.md) — **Status:** The switch side is applied. The CRS317 side is hand-applied and outstanding. — Configure the main switch and its management.
- [`css610-cutover`](css610-cutover.md) — **Status:** Outstanding. This is the first window in which devices move. — Configure the access switch ports by hand.
- [`crs804-mgmt`](crs804-mgmt.md) — **Status:** Outstanding. Do this last of the switches, after charon is in mgmt. — Move the spine management address to the mgmt VLAN.
- [`balteus-vlan`](balteus-vlan.md) — **Status:** Outstanding. — Set up the VLAN-aware bridge on Proxmox.
- [`compat-retirement`](compat-retirement.md) — **Status:** Outstanding. Do this after the last device leaves the compat segment. — Remove the compat VLAN and set PVID 999.

## Operations
- [`router-bootstrap`](router-bootstrap.md) — **Status:** Partly outstanding. Check the list in the agent source before you start. — Manage backups and set up the CI user.
- [`ci-runner`](ci-runner.md) — **Status:** Operational. The runner is built. Use this runbook for recovery. — Build the CI runner and recover a dead broker session.
- [`state-lock`](state-lock.md) — **Status:** Operational. Use this runbook when an apply dies and leaves a lock. — Clear a stale OpenTofu lock.
- [`openbao`](openbao.md) — **Status:** Operational. The vault is working. Use this runbook for restarts, snapshots and seeding. — Manage the Vault LXC and seed secrets.

## Clusters
- [`cluster-lifecycle`](cluster-lifecycle.md) — **Status:** Operational. Use this runbook to create or to destroy a cluster. — Provision and destroy Talos clusters.
- [`talos-template`](talos-template.md) — **Status:** Operational. Use this runbook when you must rebuild the Proxmox template. — Build the Proxmox template for cluster nodes.
