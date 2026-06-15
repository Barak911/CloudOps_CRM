# Monitoring Stack

Prometheus, Grafana, and a real `PrometheusRule` + Alertmanager routing tree for the CRM application. Receivers are null stubs in this portfolio deployment — swap one for a Slack/PagerDuty webhook to go live.

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Prometheus | monitoring | Metrics collection + rule evaluation (10Gi, 2d retention) |
| Grafana | monitoring | Dashboards and visualization (5Gi persistence) |
| Alertmanager | monitoring | Severity-routed alert delivery (real routing tree, null receivers) |
| Node Exporter | monitoring | Host-level metrics (DaemonSet) |
| Kube State Metrics | monitoring | Kubernetes object metrics |
| `crm-app-rules` | crm | App SLO burn-rate alerts + platform health rules (PrometheusRule CRD) |

The Prometheus instance is configured with `ruleNamespaceSelector: {}` so it discovers PrometheusRule resources cluster-wide — `crm-app-rules` lives in the `crm` namespace alongside the workload it watches.

## Application Metrics

The CRM app exposes Prometheus metrics at `/metrics`:

- `flask_http_request_total` — Total HTTP requests (by method, status, path)
- `flask_http_request_duration_seconds_bucket` — Request latency histogram
- `flask_http_request_exceptions_total` — Unhandled exceptions

### Example PromQL Queries

```promql
# Request rate by endpoint
rate(flask_http_request_total{job="crm-app"}[5m])

# P95 latency
histogram_quantile(0.95, rate(flask_http_request_duration_seconds_bucket{job="crm-app"}[5m]))

# Error rate (5xx)
rate(flask_http_request_total{job="crm-app",status=~"5.."}[5m])
```

## Alerting

Defined in [`k8s/manifests/crm-prometheusrules.yaml`](manifests/crm-prometheusrules.yaml). Two rule groups:

### `crm-app.slo` — error-budget burn-rate alerts (Google SRE multi-window)

SLO: **99%** of `crm-app` HTTP requests over a rolling 30-day window must succeed (non-5xx). Two recording rules pre-compute the error ratio over multiple windows; two alerts fire at distinct urgencies:

| Alert | Condition | Severity | Window | What it means |
|---|---|---|---|---|
| `CRMAppErrorBudgetFastBurn` | 5m AND 1h error rate > 14.4 × 0.01 for 2m | `page` | both | At this rate the 30-day budget is exhausted in <2 days |
| `CRMAppErrorBudgetSlowBurn` | 30m AND 6h error rate > 6 × 0.01 for 15m | `ticket` | both | At this rate the budget is exhausted in <3 days |
| `CRMAppP95LatencyHigh` | p95 latency > 500ms for 10m | `ticket` | 5m bucket | Latency SLO breach |
| `CRMAppDown` | `up{job="crm-app"} == 0` for 3m | `page` | n/a | Prometheus can't reach the target |

Two-window confirmation per severity (5m + 1h, 30m + 6h) reduces false positives from short blips.

### `crm-platform.health` — platform health

| Alert | Condition | Severity |
|---|---|---|
| `KubePodCrashLooping` | `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}` in crm/monitoring/argocd for 5m | `page` |
| `PVCNearFull` | PVC used / capacity > 0.85 for 10m | `ticket` |
| `MongoDBDown` | `absent(up{job=~"crm-stack-mongodb\|mongodb"} == 1)` for 3m | `page` |

`MongoDBDown` will sit in `state=pending` until a `mongodb_exporter` is added — that's expected; it's the alert wired *up*, not the absence of the metric source.

## Alertmanager Routing

Defined in [`k8s/values/prometheus-values.yaml`](values/prometheus-values.yaml) under `alertmanager.config`:

```
route
├── group by: [alertname, namespace, severity]
├── default receiver: default-null
└── routes:
    ├── severity = page    → pager-null   (continue: true)
    └── severity = ticket  → ticket-null

inhibit_rules:
  └── CRMAppDown suppresses crm-app-*-* alerts in the same namespace
      (don't page on burn-rate when the whole target is down)
```

All three receivers (`default-null`, `pager-null`, `ticket-null`) are intentionally empty — the routing tree is real but the destinations are stubs for this portfolio deployment. Swap any one of them for a Slack `webhook_configs` block or PagerDuty `pagerduty_configs` and the wiring is live.

## Retention and Storage

Prometheus retention is set to **2 days** (`retention: 2d`) to keep disk usage within the 10Gi volume on the cost-optimized EKS cluster. This means:

- Metrics older than 48 hours are automatically deleted.
- Grafana dashboards only show up to 2 days of history.
- For longer retention, increase the PVC size and adjust `retention` in `prometheus-values.yaml`.

## ServiceMonitor

[`k8s/manifests/crm-servicemonitor.yaml`](manifests/crm-servicemonitor.yaml) tells Prometheus to scrape `/metrics` every 30s from pods matching `app: crm-app`. Cross-namespace discovery is enabled at the Prometheus CR level (`serviceMonitorNamespaceSelector: {}`), so the ServiceMonitor in `crm` is found by Prometheus in `monitoring`.

## Verifying the alert pipeline

```bash
# Are the rules loaded into Prometheus?
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/rules \
  | python3 -c "import sys,json; [print('  '+r['name']+': '+r.get('state','rec'))
      for g in json.load(sys.stdin)['data']['groups'] if g['name'].startswith('crm-')
      for r in g['rules']]"

# Are the scrape targets healthy?
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | python3 -c "import sys,json; [print('  job='+t['labels']['job']+' health='+t['health'])
      for t in json.load(sys.stdin)['data']['activeTargets']
      if 'crm-app' in t['labels'].get('job','')]"
```

## Accessing Grafana

```bash
INGRESS_URL=$(kubectl get svc nginx-ingress-ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: https://$INGRESS_URL/grafana"
# Login: admin / (kubectl get secret prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)
```

## CRM Dashboard Panels

Defined in [`k8s/manifests/crm-dashboard-configmap.yaml`](manifests/crm-dashboard-configmap.yaml), auto-imported via the Grafana sidecar (`label: grafana_dashboard=1`):

1. HTTP Request Rate (`rate(flask_http_request_total)`)
2. HTTP Request Duration (p95 via `histogram_quantile`)
3. Total Requests by Status Code
4. Error Rate (5xx) with thresholds
5. Request Count by Endpoint
6. HTTP Methods Distribution
7. Average Request Duration
8. Application Info

## Cleanup

```bash
helm uninstall prometheus-stack -n monitoring
kubectl delete namespace monitoring
# The PrometheusRule + ServiceMonitor live in `crm`; they're cleaned up by
# the crm-manifests ArgoCD application along with the rest of the namespace.
```
