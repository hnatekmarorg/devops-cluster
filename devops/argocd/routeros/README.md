# MikroTik / RouterOS management via Crossplane

The RB5009 gateway's configuration is declared here and reconciled by Crossplane in
this cluster (`devops`), using **provider-opentofu** to run
[terraform-routeros](https://github.com/terraform-routeros/terraform-provider-routeros)
workspaces in-cluster.

## Why this stack

| Option | Verdict |
|---|---|
| `upbound/provider-opentofu` + `terraform-routeros` | **chosen** — actively maintained; full RouterOS resource coverage (254 resources upstream) |
| `crossplane-contrib/provider-terraform` | frozen at Terraform 1.5.7 (BSL avoidance); its README now points at provider-opentofu |
| `sindrip/provider-routeros` | native MikroTik provider with a nice resource-identity model, but 5 weeks old / single maintainer — re-evaluate later, don't trust the router to it yet |

## Files

| File | Purpose |
|---|---|
| `00-provider.yaml` | Installs the Crossplane provider package |
| `10-providerconfig.yaml` | Provider block, provider version pin, Kubernetes state backend |
| `20-workspace-smoke.yaml` | Read-only smoke test (data sources only) — proves credentials + API path |
| `30-workspace-network.yaml` | Stage 1 groundwork: VLAN interfaces, gateways, firewall address-lists |

## Required router preparation (once)

1. Create a service user (RouterOS `apiss://`/`api` policy) and set its password:

   ```routeros
   /user group add name=crossplane policy=api,read,write,test comment="crossplane IaC"
   /user add name=iac group=crossplane comment="crossplane IaC"
   /user set iac password="<openssl rand -base64 24>"
   ```

   Start with no `address=` restriction and tighten it once the workspaces are
   known to authenticate — the source IP is whichever node egresses to the
   router, not the Hermes host. Verify with `ROS_HOSTURL=apis://172.16.100.1:8729`
   (API-SSL is already enabled; REST/web-ssl is not needed).

2. Put that password into the SOPS secret (`secrets/routeros-iac.yaml` →
   `./scripts/encrypt.sh`, or edit the encrypted file directly with
   `sops devops/argocd/secrets/enc.routeros-iac.yaml`). The committed secret
   ships with the placeholder `CHANGE_ME_ROUTEROS_IAC_PASSWORD`; the workspaces
   simply fail to authenticate until it is replaced (no router changes either
   way).

## Safety model

- **Stage 1 is additive.** It creates new VLAN interfaces, gateway addresses and
  address-lists. It touches nothing that already exists, and the VLANs carry no
  traffic until the bridge becomes VLAN-aware (stage 2).
- The bridge is *not* modified here — no `vlan-filtering`, no tagged ports, no
  DHCP, no firewall rules. Those arrive in later stages, each reviewed on its
  own.
- **Existing objects can be adopted later** without recreation: terraform-routeros
  supports `terraform import`, and OpenTofu ≥1.5 understands `import {}` blocks,
  so a future stage can pull the current bridge / DHCP / firewall objects under
  management declaratively.
- Workspaces default to `deletionPolicy: Delete` — deleting a manifest destroys
  its RouterOS objects. Set `spec.deletionPolicy: Orphan` on a workspace if you
  ever want removal to leave the router untouched.
- State is stored in Secrets (`crossplane-system`, key
  `<secret_suffix>-<workspace>`). Losing state does not damage the router, but
  the next apply re-creates what it cannot find in state.

## Operating it

```bash
kubectl get workspaces
kubectl describe workspace routeros-smoke
kubectl get secret -n crossplane-system routeros-smoke -o jsonpath='{.data}' | base64 -d
kubectl logs -n crossplane-system deploy/provider-opentofu-<hash>
```

If the Kubernetes state backend fails with RBAC errors, the provider needs
secret permissions in `crossplane-system` — add a ClusterRole patch in that case.

## Roadmap

1. **Stage 2** — bridge VLAN filtering + tagged ports, per-VLAN DHCP servers,
   internal DNS (dnsmasq regexp → ingress VIP), firewall matrix (default-deny
   east-west + `wan-restricted` egress class in log-only mode).
2. **Stage 3** — WireGuard server + peers (client keys minted via OpenBao),
   `vpn.hnatekmar.dev` DDNS record.
3. **Stage 4** — adopt pre-existing objects via `import {}` blocks; drift
   reporting via nightly `plan` (workspaces can run in `managementPolicies: [Observe]`).
