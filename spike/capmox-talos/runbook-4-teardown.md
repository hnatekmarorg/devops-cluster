# Runbook 4 — ending the spike

The spike is over when the four measurements in `README.md` are recorded. Then remove all of it, in this
order, so nothing is left half-alive:

1. **Delete the cluster**

   ```bash
   kubectl delete -f manifests/cluster-talos-proxmox.yaml
   kubectl -n default get proxmoxmachine        # must be empty
   # on balteus: qm list | grep spike           # must be empty — no orphan VMs
   ```

   If a `ProxmoxMachine` hangs in deletion, CAPMOX has an open issue about not tracking async
   stop/destroy task failures (#742) — check the Proxmox task log and remove the VM by hand, but write down
   that you had to.

2. **Delete the management plane**

   ```bash
   clusterctl delete --all        # on the k3s VM (or just destroy the VM — faster and equally final)
   ```

3. **The Talos template** — `qm destroy 9000` if no further attempt is imminent; otherwise leave it, it is
   inert and saves a re-download.

4. **The repo** — this is a spike PR, so **closing it unmerged is a legitimate outcome**. If it merged,
   delete `spike/capmox-talos/` and revert the `k3s.srv.hnatekmar.dev` record in the same PR (the router apply
   runs on merge, so the revert lands the same way the record did).

5. **Record the outcome where the next person looks.** The four measurements, H1's answer, H2's answer, the
   version set that worked, and the one thing you would do differently. `terraform/docs/` is where the
   carve's reasoning lives; the cluster story deserves its own file there — and once the vault's NFS is back,
   a note in `projects/` so it survives the repo overhaul.
