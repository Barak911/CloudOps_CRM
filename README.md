# CloudOps CRM

**Production-grade Kubernetes platform** on AWS EKS — GitOps delivery with ArgoCD, full observability stack (Prometheus + Grafana + EFK), and automated CI/CD pipelines.

Built as a monorepo: application code, Helm charts, Terraform infrastructure, and CI/CD workflows all in one place.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Application** | Python Flask REST API, Gunicorn, MongoDB |
| **Containers** | Docker (multi-stage builds), Amazon ECR |
| **Orchestration** | Kubernetes (AWS EKS), Helm umbrella chart |
| **GitOps** | ArgoCD — auto-syncs from Git after one-time bootstrap |
| **CI/CD** | GitHub Actions with OIDC auth (no stored AWS keys) |
| **Infrastructure** | Terraform (EKS, ECR, IAM OIDC, EBS CSI, KMS) |
| **Monitoring** | Prometheus, Grafana, ServiceMonitor CRDs |
| **Logging** | Fluentd (DaemonSet) -> Elasticsearch -> Kibana |
| **Networking** | Nginx Ingress Controller, single AWS NLB for all services |
| **Secrets** | AWS Secrets Manager + ExternalSecrets Operator (IRSA) |
| **Security** | Pod security contexts, read-only root FS, Trivy + pip-audit scans, OIDC (no stored keys) |

## Architecture

```
                        +-----------------+
                        |   Developer     |
                        |   git push      |
                        +--------+--------+
                                 |
                                 v
                     +-----------+-----------+
                     |   GitHub Actions CI   |
                     |  Build > Test > Scan  |
                     |  Push to ECR          |
                     |  Commit new image tag |
                     +-----------+-----------+
                                 |
                          [skip ci] commit
                                 |
                                 v
                     +-----------+-----------+
                     |       ArgoCD         |
                     |  Detects Git change  |
                     |  Syncs to cluster    |
                     +-----------+-----------+
                                 |
                                 v
     +-----------------------------------------------------------+
     |                    AWS EKS Cluster                        |
     |                                                           |
     |   Nginx Ingress Controller (single NLB)                   |
     |     /          ->  CRM Flask App  <->  MongoDB            |
     |     /kibana    ->  Kibana                                 |
     |     /grafana   ->  Grafana                                |
     |     /argocd    ->  ArgoCD Dashboard                       |
     |                                                           |
     |   Fluentd (DaemonSet) -> Elasticsearch                    |
     |   Prometheus -> Grafana (+ CRM ServiceMonitor)            |
     +-----------------------------------------------------------+
```

### GitOps Flow

```
1. Developer pushes to app/           4. ArgoCD detects tag change in Git
2. CI builds, tests, scans, pushes    5. ArgoCD syncs cluster to desired state
3. CI commits new image tag [skip ci] 6. New version is live — zero manual steps
```

**CI** (GitHub Actions) owns: build, test, vulnerability scan, ECR push, image tag update.
**CD** (ArgoCD) owns: every Kubernetes deployment after initial bootstrap.

> **Note:** The one-time `bootstrap-cluster.yml` workflow imperatively installs ArgoCD, ExternalSecrets Operator,
> and performs initial Helm deploys so ArgoCD can adopt them. After bootstrap, all ongoing deploys are GitOps-driven —
> CI commits image tags and ArgoCD syncs the cluster. See [Key Design Decisions](#key-design-decisions) for rationale.

## Repository Structure

```
CloudOps_CRM/
├── .github/workflows/
│   ├── ci.yml                    # CI: build, test, scan, push, update tag
│   ├── bootstrap-cluster.yml     # One-time EKS cluster bootstrap
│   └── cleanup-deployment.yml    # Full teardown workflow
│
├── app/                          # Flask CRM application
│   ├── app.py                    # REST API (CRUD + search + bulk ops + pagination)
│   ├── Dockerfile                # Multi-stage build with .dockerignore
│   ├── test_app.py               # 18 unit tests (pytest)
│   ├── test_e2e.sh               # 20 end-to-end tests
│   ├── requirements.txt          # Runtime deps only
│   ├── requirements-dev.txt      # Runtime + test deps
│   └── docker-compose.test.yml   # E2E test environment
│
├── k8s/
│   ├── crm-stack/                # Helm umbrella chart
│   │   ├── Chart.yaml            # Dependencies: crm-app, mongodb, ES, Kibana, Fluentd
│   │   ├── values.yaml           # CI auto-updates image.tag here
│   │   └── charts/               # Subcharts (crm-app, mongodb are custom)
│   ├── argocd/                   # ArgoCD Application CRDs
│   │   ├── crm-stack-app.yaml    # CRM + MongoDB + EFK (multi-source)
│   │   ├── prometheus-app.yaml   # Prometheus + Grafana (multi-source)
│   │   ├── nginx-ingress-app.yaml# Ingress Controller (multi-source)
│   │   └── manifests-app.yaml    # Ingress rules, ServiceMonitor, dashboard
│   ├── manifests/                # Plain K8s manifests (Ingress, ServiceMonitor, ExternalSecrets)
│   └── values/                   # Per-environment Helm value overrides
│
├── infra/                        # Terraform (AWS)
│   ├── eks.tf                    # EKS cluster + managed node group
│   ├── ecr.tf                    # Container registry (immutable tags)
│   ├── github-oidc.tf            # OIDC federation (no stored AWS keys)
│   ├── ebs-csi-driver.tf         # Persistent storage (gp3 default)
│   ├── secrets.tf                # AWS Secrets Manager + IRSA for ExternalSecrets
│   ├── backend.tf                # S3 remote state
│   └── ARCHITECTURE.md           # Infrastructure documentation
│
├── Makefile                      # Developer shortcuts (test, build, lint, plan)
└── CHANGELOG.md                  # Full change history across all phases
```

## Key Design Decisions

| Decision | Why |
|----------|-----|
| **Monorepo** | App, infra, and K8s in one repo = atomic changes, single PR for full-stack features |
| **ArgoCD over Helm-in-CI** | After bootstrap, cluster state is always in Git. Drift detection + self-healing. No `kubectl` in day-2 pipelines. |
| **Multi-source ArgoCD Apps** | Helm chart from one source, values from another — clean separation of config vs charts |
| **OIDC federation** | GitHub Actions authenticates to AWS via short-lived tokens. Zero stored secrets. |
| **ExternalSecrets** | MongoDB credentials stored in AWS Secrets Manager, synced to K8s via IRSA — no secrets in Git or CLI args |
| **Least-privilege CI** | GitHub Actions uses OIDC federation (no stored keys). Bootstrap requires cluster-admin for CRD/namespace creation; a production refinement would use separate roles for bootstrap vs day-2 CI. |
| **Helm umbrella chart** | CRM app + MongoDB + EFK deployed as a single unit with shared config (namespace, labels) |
| **Immutable ECR tags** | Every image tagged with commit SHA — no `latest` in production, full traceability |
| **Pod security contexts** | `readOnlyRootFilesystem`, `runAsNonRoot`, `drop: ALL` capabilities — defense in depth |
| **Single Ingress NLB** | One AWS load balancer routes all traffic — cost-effective, centralized TLS termination point |

## Known Limitations & Production Hardening

This project is a fully working demo. For production use, consider the following:

| Area | Current State | Production Recommendation |
|------|--------------|--------------------------|
| **EKS API endpoint** | Public (`0.0.0.0/0`) — easy bootstrap from anywhere | Restrict `cluster_endpoint_public_access_cidrs` to VPN/office CIDRs in `terraform.tfvars`, or disable public access entirely |
| **VPC** | Default VPC with public subnets | Dedicated VPC with private subnets + NAT gateway for node groups |
| **IAM — CI role** | `cluster-admin` for both bootstrap and day-2 CI | Separate bootstrap role (cluster-admin) from day-2 CI role (ECR push + namespace edit) |
| **IAM — developer** | `cluster-admin` when `developer_user_arn` is set | Scope to read-only or namespace-level access depending on role |
| **ECR force_delete** | `false` (safe default, override with `-var='ecr_force_destroy=true'`) | Keep `false` in production; use `true` only for dev/test teardown |
| **TLS** | Self-signed cert via Nginx Ingress fake cert | ACM certificate + Route53 DNS for a real domain |
| **Bootstrap workflow** | Imperative installs (ArgoCD, CRDs, initial Helm deploy) | Expected — bootstrap is a one-time operation; all ongoing deploys are GitOps |

## Quick Start

### Prerequisites

- AWS CLI configured
- Terraform >= 1.10
- kubectl, Helm 3.x, Docker

### 1. Provision Infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="region=YOUR_BUCKET_REGION"
terraform apply
```

### 2. Bootstrap the Cluster

Run the **Bootstrap EKS Cluster** workflow from GitHub Actions (manual trigger).

This installs ArgoCD, bootstraps all services, and runs integration tests.

### 3. Ongoing Deployments

Push to `app/` on `main` — CI builds, tests, pushes to ECR, commits new image tag. ArgoCD auto-syncs. Done.

### 4. Local Development

```bash
cd app && cp .env.example .env
docker compose up -d          # App at http://localhost:5000
pytest test_app.py -v         # 18 unit tests
./test_e2e.sh                 # 20 E2E tests (requires docker compose)
```

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check |
| GET | `/person` | List all (supports `?page=&limit=`) |
| GET | `/person/<id>` | Get by custom ID |
| GET | `/person/search?q=<term>` | Search by name or email |
| POST | `/person/<id>` | Create |
| PUT | `/person/<id>` | Update |
| DELETE | `/person/<id>` | Delete |
| POST | `/person/bulk` | Bulk create |
| DELETE | `/person/bulk` | Bulk delete |
| GET | `/stats` | Collection statistics |
| GET | `/metrics` | Prometheus metrics |

## Dashboards (after deployment)

| Service | Path | Credentials |
|---------|------|-------------|
| CRM App | `/` | None |
| Kibana | `/kibana` | `elastic` / (from K8s secret) |
| Grafana | `/grafana` | `admin` / (from K8s secret) |
| ArgoCD | `/argocd` | `admin` / (from K8s secret) |

## Documentation

| Document | Contents |
|----------|----------|
| [`infra/ARCHITECTURE.md`](infra/ARCHITECTURE.md) | Infrastructure design, CI/CD flow, security model |
| [`infra/SETUP.md`](infra/SETUP.md) | Step-by-step deployment guide |
| [`infra/TROUBLESHOOTING.md`](infra/TROUBLESHOOTING.md) | Common issues and fixes |
| [`k8s/MONITORING.md`](k8s/MONITORING.md) | Observability stack setup |
| [`CHANGELOG.md`](CHANGELOG.md) | Complete change history |
