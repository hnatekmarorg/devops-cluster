# cluster-base

Foundational infrastructure for one cluster, rendered as one ArgoCD Application per component:
cert-manager (with its Cloudflare credential), the External Secrets Operator and its secret store,
Karpenter and the cloud controller, nginx ingress, MetalLB, storage (NFS + NVMe-oF), Crossplane and this
cluster's Keycloak writer, the RBAC bindings — and, when a cluster turns it on, monitoring.

Each per-cluster value is documented inline in `values.yaml`, and the per-cluster *statements* live in
`bootstrap/argocd/<cluster>/cluster-base.yaml`. This file covers the parts that need a how-to rather than
an explanation: the monitoring stack and, in more detail, **the alert path**.

---

## Monitoring

Off by default; enabled per cluster with `monitoring.enabled` (see the block comment in `values.yaml` for
why it is a per-cluster statement, and why the alert path points at Telegram rather than at the estate's
own ntfy).

What `monitoring.enabled: true` renders:

| Piece | Where | Why it is here |
| --- | --- | --- |
| kube-prometheus-stack | `templates/monitoring/kube-prometheus-stack.yaml` | Prometheus, Alertmanager, Grafana, the operator, kube-state-metrics, node-exporter and 139 tuned alert rules — one chart, one Application |
| its CRDs | same, `crds.enabled: true` | without them every `monitoring.coreos.com` object below applies to nothing |
| the `monitoring` namespace | `templates/monitoring/namespace.yaml` | declared here so it can carry the `privileged` Pod Security labels node-exporter needs |
| cert-manager + ESO scrapers | `templates/monitoring/scrapers.yaml` | the two components this estate's own rules read |
| this estate's rules | `templates/monitoring/rules.yaml` + `files/estate-rules.yaml` | the faults the chart's defaults do not cover |
| the alert receiver | `templates/monitoring/kube-prometheus-stack.yaml` | Alertmanager → Telegram (the chart's own Alertmanager datasource is what makes Silences clickable in Grafana) |
| Grafana's OIDC client | `templates/monitoring/grafana-oidc.yaml` | created by *this* cluster's Keycloak writer; nothing is carried over by hand |
| the bot token | `templates/monitoring/alertmanager-telegram.yaml` | from the vault, mounted as a file |

### The alert path

```
Prometheus ──rule──▶ Alertmanager ──receiver──▶ Telegram ──▶ a phone
                                     (srv -> internet)
```

Telegram is a **native Alertmanager receiver**: no relay container, no second service to keep alive and
nothing between the alert and the phone that can fail on its own. The reason it is not the estate's own
ntfy is the firewall matrix — the clusters are `srv`-class and the matrix gives srv `responses only`
towards mgmt, while ntfy lives on the mgmt plane. Push in that direction would be built on a row the
matrix means to close. (`mgmt -> srv` *is* allowed, as "monitoring scrape", so the matrix-legal way to
also get alerts into ntfy later is a **pull** from the admin plane reading this Alertmanager's
`/api/v2/alerts`.)

Two knobs, both per cluster: `monitoring.alertmanager.telegram.chatId` (an id, not a secret) and
`monitoring.alertmanager.telegram.vaultKey` (defaults to `common/telegram` — one bot for the whole
estate). The token is read through the cluster's own `ClusterSecretStore` and mounted as a file, so it is
never in the rendered Alertmanager config.

**The bot must already be able to see the destination.** A bot cannot start a chat: talk to it once, or
add it to the group, before the first alert can arrive. Otherwise every send fails with `chat not found`
and the alert path reads as broken from the cluster's side.

### The daily heartbeat

Alertmanager's own `Watchdog` alert — always firing, routed to a receiver that re-sends it every
`monitoring.alertmanager.watchdogHeartbeat.repeatInterval` (24h). Silence of **that** message is the
signal: a delivery path that has stopped is otherwise indistinguishable from a quiet week, and nothing
else in the stack notices. It is also the one alert that is worthless in a dashboard — which is the point.

### Adding an alert

1. **Check the chart's defaults first.** kube-prometheus-stack ships 139 rules (node, kubelet, API server,
   etcd, PVCs, certificates, Prometheus and Alertmanager self-checks). A second rule for a covered fault
   means two alerts for one problem.
2. Estate-specific rules go in `files/estate-rules.yaml` and are validated standalone:
   ```
   promtool check rules charts/cluster-base/files/estate-rules.yaml
   ```
3. Annotations there may use Go template syntax (`{{ $labels.name }}`) because that file is **not**
   processed by Helm. Inline in a template it would be — the two engines use the same delimiters, and Helm
   renders first.
4. `severity` decides the route: `critical` gets its own receiver and a 10s `group_wait`; everything else
   takes the default route. `InfoInhibitor` is routed to a null receiver by design.
5. Rules inherit no labels from the file: every alert already carries `cluster=<clusterName>`, set once as
   a Prometheus `externalLabel`.

### Silencing something

Grafana is the only exposed door, and the chart provisions Alertmanager in it as a datasource already
(`kube-prometheus-stack-grafana-datasource`), so silencing is **Alerting → Silences** in Grafana — or the
Alertmanager API from inside the cluster:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
amtool --alertmanager.url=http://localhost:9093 silence add alertname=ExampleAlert
```

Alertmanager is deliberately not published through an ingress: it has no authentication of its own.

### Validating a change to the alert path

The Alertmanager config is part of the Application's Helm values, so it can be checked before it is
committed — and a config that does not parse is an Alertmanager that does not start, i.e. alerts that
silently stop:

```bash
helm template cluster-base charts/cluster-base -f <rendered cluster values> > /tmp/cb.yaml
amber=$(python3 -c "import yaml,sys; d=[x for x in yaml.safe_load_all(open('/tmp/cb.yaml')) if x and x['kind']=='Application' and x['metadata']['name']=='kube-prometheus-stack'][0]; print(d['spec']['source']['helm']['valuesObject']['alertmanager']['config'])" )
amtool check-config <<<"$amber"
```

### First install of the stack (order matters once)

1. `./scripts/seed-vault.sh telegram` — the bot token (needs an operator vault token, not CI's).
2. Set `monitoring.alertmanager.telegram.chatId` in this cluster's values.
3. **prod only:** apply the cluster's service-name DNS record (`terraform/routeros/dns.tf`,
   `prod_cluster_services`). Dev's wildcard already exists; without prod's, `grafana.prod-k8s...` answers
   the public `*.hnatekmar.dev` wildcard and lands on machines that do not serve it.
4. Let it sync. ArgoCD's waves do the ordering: namespace (-1) → bot token (0) → the stack (1) → scrapers
   and rules (3). Nothing needs applying by hand.

### Not in scope

* **Logs.** No Loki/Alloy: metrics and alerting only.
* **Published remote-write.** Prometheus accepts remote write (`enableRemoteWriteReceiver`) but the
  endpoint is cluster-internal and unauthenticated; exposing it needs an ingress and an auth decision.
* **A public Alertmanager.** See *Silencing* above.
