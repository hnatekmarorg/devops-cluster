# Vendored chart — truenas-csi 1.3.0

This is the upstream `truenas-csi` chart, copied into this repository because **one hostPath type cannot be
expressed from outside it** and the estate will not wait on an upstream release for a one-word change.

## The two deviations from upstream 1.3.0

| # | file | change | why |
|---|---|---|---|
| 1 | `templates/node.yaml` | `iscsi-dir` hostPath `Directory` → **`DirectoryOrCreate`** | Talos' kubelet runs in a distro image whose `/etc` is curated (only `/etc/hosts`, `/etc/resolv.conf`, `/etc/kubernetes`, `/etc/cni`, `/etc/nfsmount.conf`, `/etc/machine-id` are bound in), so a strict hostPath of `/etc/iscsi` fails its type check however healthy the host is, and no node can ever stage a volume. `DirectoryOrCreate` makes kubelet create the directory in its own view; the volume then resolves against the host's `/etc`, where the file already is. |
| 2 | `templates/controller.yaml`, `templates/node.yaml` | `checksum/config` annotation on the pod template | the driver reads its URL/portal/pool from the ConfigMap as env vars, resolved at container start — a changed value does **not** roll the pods (measured: a corrected `nvmeofPortal` needed a manual `rollout restart`). |

`machine.kubelet.extraMounts` would have been the place to fix #1 without touching the chart, and it is
impossible on Talos v1.14: the generated config carries a `KubeletConfig` document, so any
`.machine.kubelet` patch is refused (`kubelet config is already set in v1alpha1 config`), and that document
has no mounts field (`image`, `config`, `extraArgs`, `clusterDNS`, `defaultRuntimeSeccompProfileEnabled`;
its `ExtraMounts` accessor returns `nil`). Measurements live in the module's `patches.tf` too.

## Re-syncing to a new upstream release

```bash
helm pull truenas-csi/truenas-csi --version <X.Y.Z> --untar -d /tmp/upstream
rsync -a --delete /tmp/upstream/truenas-csi/ charts/truenas-csi/ \
  --exclude VENDORED.md --exclude vendored-deviations.patch
cd charts/truenas-csi && patch -p1 < vendored-deviations.patch
```

`vendored-deviations.patch` is the exact diff, regenerated whenever the deviations change. If the patch
applies with fuzz, read the two rows above and re-apply them by hand — they are small on purpose.

## What is deliberately NOT vendored

Anything else. The chart stays as close to upstream as possible so a re-sync is mechanical; features that
upstream adds are picked up by the copy, and our own resource definitions (the Application, the vault
secret, the StorageClass values) stay in `charts/cluster-base`.
