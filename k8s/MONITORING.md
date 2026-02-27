# Monitoring Stack

Prometheus and Grafana monitoring for the CRM application.

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Prometheus | monitoring | Metrics collection and storage (10Gi, 2d retention) |
| Grafana | monitoring | Dashboards and visualization (5Gi persistence) |
| AlertManager | monitoring | Alert routing |
| Node Exporter | monitoring | Host-level metrics (DaemonSet) |
| Kube State Metrics | monitoring | Kubernetes object metrics |

## Application Metrics

The CRM app exposes Prometheus metrics at `/metrics`:

- `flask_http_request_total` -- Total HTTP requests (by method, status, path)
- `flask_http_request_duration_seconds` -- Request latency histogram
- `flask_http_request_exceptions_total` -- Unhandled exceptions

### Example PromQL Queries

```promql
# Request rate by endpoint
rate(flask_http_request_total{job="crm-app"}[5m])

# P95 latency
histogram_quantile(0.95, rate(flask_http_request_duration_seconds_bucket{job="crm-app"}[5m]))

# Error rate (5xx)
rate(flask_http_request_total{job="crm-app",status=~"5.."}[5m])
```

## Retention and Storage

Prometheus retention is set to **2 days** (`retention: 2d`) to keep disk usage within the 10Gi volume on the cost-optimized EKS cluster. This means:

- Metrics older than 48 hours are automatically deleted.
- Grafana dashboards only show up to 2 days of history.
- For longer retention, increase the PVC size and adjust `retention` in `prometheus-values.yaml`.

## ServiceMonitor

The `crm-servicemonitor.yaml` tells Prometheus to scrape `/metrics` every 30s from pods matching `app: crm-app`.

## Accessing Grafana

```bash
INGRESS_URL=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: http://$INGRESS_URL/grafana"
# Login: admin / <password set during deployment>
```

## CRM Dashboard Panels

1. HTTP Request Rate
2. HTTP Request Duration (P95)
3. Total Requests by Status Code
4. Error Rate (5xx) with thresholds
5. Request Count by Endpoint
6. HTTP Methods Distribution
7. Average Request Duration
8. Application Info

## Cleanup

```bash
helm uninstall prometheus -n monitoring
kubectl delete namespace monitoring
kubectl delete servicemonitor crm-app-metrics -n default
```
