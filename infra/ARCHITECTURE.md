# Architecture

Cloud-native CRM application deployed on AWS EKS with ArgoCD GitOps and full observability.

## Monorepo Structure

```
CloudOps_CRM/
├── app/          # Flask REST API + tests + Dockerfile
├── k8s/          # Helm charts, ArgoCD Applications, manifests
│   ├── crm-stack/    # Umbrella chart (CRM + MongoDB + EFK)
│   ├── argocd/       # ArgoCD Application CRDs
│   ├── manifests/    # Plain K8s resources (Ingress, ServiceMonitor)
│   └── values/       # Override values for all charts
├── infra/        # Terraform (EKS, ECR, IAM OIDC, EBS CSI)
└── .github/workflows/
```

## Deployment Architecture

```
                    Internet
                       |
              AWS Network Load Balancer
                       |
              Nginx Ingress Controller
             /     |       |       \
           /     /kibana  /grafana  /argocd
        CRM App  Kibana   Grafana   ArgoCD
          |        |         |
        MongoDB  Elasticsearch  Prometheus
                     |
                  Fluentd
                 (DaemonSet)
```

**Components:**
- Nginx Ingress Controller -- single NLB entry point
- CRM App -- Flask REST API (ClusterIP)
- MongoDB -- StatefulSet with 5Gi EBS
- Elasticsearch -- HTTPS, 5Gi EBS
- Kibana -- log visualization via Ingress
- Fluentd -- log collection DaemonSet
- Prometheus/Grafana -- monitoring namespace
- ArgoCD -- GitOps deployment controller

## AWS Infrastructure

```
AWS Account
  Default VPC (multi-AZ public subnets)
    EKS Cluster (Kubernetes 1.31)
      Managed Node Group: 2x t3a.medium (ON_DEMAND)
      EBS CSI Driver -> gp3 StorageClass (encrypted)

  ECR Repository: crm-app (immutable tags, scan-on-push)
  GitHub OIDC Role: github-actions-ecr-eks
```

## CI/CD Pipelines

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | Push to main (path: `app/**`) | Build, test, scan, push to ECR, update values.yaml |
| `bootstrap-cluster.yml` | Manual | One-time EKS cluster bootstrap via ArgoCD |
| `cleanup-deployment.yml` | Manual | Teardown ArgoCD + Helm + K8s resources |

### GitOps Flow (ci.yml)

```
git push (app/) -> Build -> Unit Tests -> Docker Build -> Trivy Scan ->
E2E Tests -> Push to ECR -> Update values.yaml tag [skip ci] ->
ArgoCD detects change -> Sync to cluster
```

### Bootstrap Flow (bootstrap-cluster.yml)

```
Build + Push to ECR -> Install ArgoCD -> Bootstrap ES + Kibana secrets ->
Apply ArgoCD Applications -> Wait for sync -> Test endpoints
```

## Observability

### EFK Stack (Logging)

App/MongoDB logs -> Fluentd DaemonSet -> Elasticsearch (HTTPS) -> Kibana

Log indices: `logs-crm`, `logs-mongodb`, `logs-system`

### Prometheus/Grafana (Monitoring)

CRM `/metrics` -> ServiceMonitor -> Prometheus -> Grafana

Metrics: `flask_http_request_total`, `flask_http_request_duration_seconds`

## Security

- OIDC authentication for GitHub Actions (no long-lived credentials)
- Non-root container (`appuser`, uid 1000) with `readOnlyRootFilesystem`
- Pod security contexts (`runAsNonRoot`, drop `ALL` capabilities)
- EKS Access Entries (not aws-auth ConfigMap)
- TLS for Elasticsearch (auto-generated certs)
- ClusterIP services (not exposed directly)
- Immutable ECR tags + scan-on-push
- Encrypted EBS volumes
- Trivy image scanning blocks CRITICAL/HIGH vulnerabilities
- Pinned GitHub Actions versions (no `@master` refs)

## Cost Optimization

- Default VPC (no NAT Gateway)
- Single NLB via Nginx Ingress
- t3a.medium instances (AMD, cost-optimized)
- `terraform destroy` when not in use
