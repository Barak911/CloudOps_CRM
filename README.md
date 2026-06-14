# CloudOps CRM

**A GitOps platform on AWS EKS — personal portfolio project exercising production-style DevOps patterns end-to-end.**

Single-developer learning project built to practice the full platform-engineering stack in one repo: Terraform infrastructure, GitHub Actions CI with AWS OIDC, ArgoCD-managed delivery, observability, and secrets management. It exercises the patterns; it is not a production deployment of them.

## Proof it ran

Most recent live bootstrap (clean account → working stack): [GitHub Actions run #27504415241](https://github.com/Barak911/CloudOps_CRM/actions/runs/27504415241).

```text
$ kubectl get applications -n argocd
NAME               SYNC STATUS   HEALTH STATUS
crm-manifests      Synced        Healthy
crm-stack          Synced        Healthy
nginx-ingress      Synced        Healthy
prometheus-stack   Synced        Healthy

$ kubectl get networkpolicies -A | wc -l
14   # default-deny + explicit allows across crm + monitoring (VPC CNI enforced)

# Prometheus rules loaded:
ALERT  crm-app.slo/CRMAppErrorBudgetFastBurn       state=inactive
ALERT  crm-app.slo/CRMAppErrorBudgetSlowBurn       state=inactive
ALERT  crm-app.slo/CRMAppP95LatencyHigh            state=inactive
ALERT  crm-app.slo/CRMAppDown                      state=inactive
ALERT  crm-platform.health/KubePodCrashLooping     state=inactive
ALERT  crm-platform.health/PVCNearFull             state=inactive
ALERT  crm-platform.health/MongoDBDown             state=pending
REC    crm-app.slo/job:flask_http_request:error_rate{5m,30m,1h,6h}

# Live scrape targets (app actually instrumented):
job=crm-app pod=crm-app-796f9f4c65-w8mds  health=up
job=crm-app pod=crm-app-796f9f4c65-7h528  health=up

# Workloads:
crm         8 pods Running    # crm-app x2, mongodb, ES, kibana, fluentd x3
monitoring  8 pods Running    # prometheus, alertmanager, grafana, kube-state, ...
argocd      5 pods Running
external-secrets  3 pods Running
cert-manager  3 pods Running
ingress-nginx 1 pod  Running
```

All workloads green on a fresh cluster brought up by the bootstrap workflow; raw captures are in [`docs/proof/`](docs/proof/).

## Scope & Intent

Built to answer one question: *can I run a real-feeling delivery pipeline solo, in a single AWS account, without papering over the hard parts?*

The patterns implemented here are the ones I'd reach for in a production environment. The **scope** is deliberately personal-account-sized — see [Out of Scope](#out-of-scope-intentionally), [Design Tradeoffs](#design-tradeoffs), and [Production Hardening](#production-hardening) below for the line between "pattern" and "fully-hardened production."

## Out of Scope (intentionally)

- Multi-AZ / cross-region high availability for MongoDB
- Separate dev / staging / prod clusters
- Real DNS + ACM-issued TLS (uses self-signed ClusterIssuer)
- Production-grade alerting, SLOs, runbooks, on-call wiring
- Multi-tenant namespace isolation / NetworkPolicies beyond basics
- Tested disaster-recovery procedure with documented RPO/RTO

Each of these is a real, distinct engineering problem. Half-implementing them as portfolio decoration would be misleading; documenting that I know they're missing is the honest version.

## Design Tradeoffs

Personal-account practicality drives a few defaults I'd flip for real production:

- **Public EKS API endpoint** — simplifies bootstrap from a laptop and GitHub-hosted runners. In prod: restrict `cluster_endpoint_public_access_cidrs` to known CIDRs, or disable public access entirely.
- **Default VPC support** — reduces setup friction. The Terraform supports a dedicated VPC with private subnets via `use_custom_vpc=true`; left off by default for runnability.
- **Single cluster** — one EKS cluster serves everything. Separate dev / staging / prod clusters are the obvious production answer.
- **Self-signed TLS** — cert-manager issues a working cert; browsers warn. Swap to Let's Encrypt or ACM + Route53 + a real domain for prod.
- **Manual bootstrap workflow** — one-time imperative install of ArgoCD and ExternalSecrets Operator, after which ArgoCD adopts everything. The chicken-and-egg of "GitOps for the GitOps controller" is an honest boundary, not a gap.

## What This Project Implements

The patterns below are the substance. Each one is end-to-end, not stubbed.

- **Infrastructure-as-code** for the full AWS footprint — EKS, ECR (immutable tags), IAM/OIDC, EBS CSI, S3 remote state, Secrets Manager — in `infra/`
- **OIDC federation** from GitHub Actions to AWS — no long-lived keys in CI secrets
- **GitOps delivery with ArgoCD** — CI writes new image SHAs into the GitOps repo; ArgoCD reconciles. Day-2 CI never touches the cluster.
- **Helm umbrella chart** packaging the app, MongoDB, and the EFK stack as a single unit with shared config
- **Observability** — Prometheus + Grafana with a ServiceMonitor for the app, Fluentd → Elasticsearch → Kibana for logs
- **Secrets management** — AWS Secrets Manager + ExternalSecrets Operator via IRSA. No secrets in Git, no static AWS keys in the cluster.
- **Pod-level hardening** — `readOnlyRootFilesystem`, `runAsNonRoot`, dropped capabilities
- **CI security scanning** — Trivy + pip-audit, fail-fast on CRITICAL/HIGH
- **Teardown workflow** — full destroy path, because building without tearing down isn't really infrastructure-as-code

## A note on the Flask app

The Python/Flask CRM in [`app/`](app/) is a deliberately thin payload — its only job is to be a real workload for the platform: it exposes Prometheus metrics, logs as JSON for the EFK pipeline, uses an IRSA-fetched MongoDB credential, and has a readiness probe that hits the database. Authentication, schema validation, and rate-limiting are intentionally out of scope; the focus is on the surrounding platform, not the application.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Application** | Python Flask REST API, Gunicorn, MongoDB |
| **Containers** | Docker (multi-stage builds), Amazon ECR |
| **Orchestration** | Kubernetes (AWS EKS), Helm umbrella chart |
| **GitOps** | ArgoCD |
| **CI/CD** | GitHub Actions with AWS OIDC federation |
| **Infrastructure** | Terraform (EKS, ECR, IAM OIDC, EBS CSI, Secrets Manager) |
| **Monitoring** | Prometheus, Grafana, ServiceMonitor CRDs |
| **Logging** | Fluentd (DaemonSet) → Elasticsearch → Kibana |
| **Networking** | Nginx Ingress Controller, single AWS NLB |
| **Secrets** | AWS Secrets Manager + ExternalSecrets Operator (IRSA) |
| **Security** | Pod security contexts, read-only root FS, Trivy + pip-audit, app-scoped DB credentials |

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
                     |       ArgoCD          |
                     |  Detects Git change   |
                     |  Syncs to cluster     |
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

### GitOps flow

```
1. Developer pushes to app/           4. ArgoCD detects tag change in Git
2. CI builds, tests, scans, pushes    5. ArgoCD syncs cluster to desired state
3. CI commits new image tag [skip ci] 6. New version is live — zero manual steps
```

**CI** owns: build, test, scan, ECR push, image-tag update.
**CD (ArgoCD)** owns: every cluster operation after initial bootstrap.

> **Bootstrap honesty.** The one-time `bootstrap-cluster.yml` workflow imperatively installs ArgoCD and ExternalSecrets Operator so ArgoCD can adopt them afterward. "GitOps from absolute zero" requires bootstrapping the GitOps controller itself with something else — that's an honest boundary, not a gap.

## Key Decisions (and the alternatives I considered first)

A few choices that aren't obvious from the file tree.

### ArgoCD over `helm upgrade` from CI

The lazy path is `helm upgrade --install` in a GitHub Actions step. Works, fewer components to operate, most small projects use it.

I picked ArgoCD because cluster state then lives in Git, not in the last successful CI log. Drift is detected and self-healed, day-2 CI doesn't need kubectl credentials, and rollback is a one-line `git revert` that ArgoCD picks up automatically. The cost: one more controller to operate, multi-source App YAMLs that aren't obvious the first time you read them, and a slower iteration loop (you commit a value change to see it apply).

For a one-developer project the cost is real. I took it on because the GitOps muscle is the one I want to build, and the discipline of "if it's not in Git, it's not in the cluster" is worth more than the saved minutes.

### Monorepo

App, infra, and Kubernetes manifests live in one repo. The split-repo alternative is what most orgs end up with at scale — one team per repo, clean boundaries, separate CI.

At one-developer scale the coordination cost of split repos is higher than the blast-radius cost of a monorepo: atomic full-stack PRs ("add a new field, route, dashboard, and metric") are one commit, not three coordinated ones. At org scale I'd split.

### ExternalSecrets + IRSA, not sealed-secrets or sops

The two common alternatives encrypt secrets in Git. They work, they're simple to bootstrap, they avoid an external dependency.

I picked ExternalSecrets because *no version of a secret* lives in Git, even encrypted. Rotating a secret is a Secrets Manager UI operation, not a git push. IRSA means the cluster also has no static AWS credentials — workloads assume roles via their pod service-account identity.

Cost: another operator to install and operate, and a hard dependency on AWS Secrets Manager. For a portfolio project that cost is mostly setup time, paid once.

### Immutable ECR tags + commit-SHA pinning

Every image is tagged with its commit SHA; `latest` is never deployed. The alternative — tag `latest` or `prod` and reuse — saves typing.

The cost is trivial; the benefit (rollback is "set the value in Git back to the previous SHA," and there's zero ambiguity about what's running) is large. Standard practice for a reason.

### Single Ingress + one NLB

Per-service load balancers are the easy default in EKS — every `Service` of type `LoadBalancer` gets its own NLB at ~$18/month before traffic.

One Nginx Ingress Controller behind a single NLB routes everything by path: cheaper, one TLS termination point to manage, easier mental model. Cost: the Ingress Controller becomes a SPOF and needs its own monitoring and upgrade discipline — manageable in practice with two replicas.

## Production Hardening

Everything in this table is a real production gap, not a stylistic preference. Current state is intentional for a personal-account portfolio; the recommendation is what I'd do for actual production.

| Area | Current State | Production Recommendation |
|------|--------------|--------------------------|
| EKS API endpoint | Public (`0.0.0.0/0`) | Restrict to known CIDRs, or disable public access entirely |
| VPC | Default VPC (custom available via `use_custom_vpc=true`) | Dedicated VPC, private subnets, NAT gateways |
| IAM — CI | `cluster-admin` for bootstrap; day-2 only pushes to ECR | Revoke bootstrap role post-setup; keep day-2 scope |
| TLS | cert-manager + self-signed `ClusterIssuer` | Let's Encrypt or ACM with Route53-validated cert, real domain |
| MongoDB HA | Single replica on EBS-backed PVC | Replica set across AZs, or managed (DocumentDB / Atlas) |
| Observability | Prometheus + Grafana + EFK installed, no alerts wired | SLO definitions, Alertmanager rules, on-call rotation, incident playbooks |
| Backups | None implemented | Velero or scheduled volume snapshots; documented restore procedure |
| Secrets rotation | Manual via Secrets Manager | Automated rotation Lambdas with downstream notification |

## Repository Structure

```
CloudOps_CRM/
├── .github/workflows/
│   ├── ci.yml                    # CI: build, test, scan, push, update tag
│   ├── bootstrap-cluster.yml     # One-time EKS cluster bootstrap
│   └── cleanup-deployment.yml    # Full teardown workflow
│
├── app/                          # Flask CRM application
│   ├── app.py                    # REST API (CRUD + search + bulk + pagination)
│   ├── Dockerfile                # Multi-stage build
│   ├── test_app.py               # 18 unit tests (pytest)
│   ├── test_e2e.sh               # 20 end-to-end tests
│   ├── requirements.txt
│   ├── requirements-dev.txt
│   └── docker-compose.test.yml   # E2E test environment
│
├── k8s/
│   ├── crm-stack/                # Helm umbrella chart
│   │   ├── Chart.yaml            # Dependencies: crm-app, mongodb, ES, Kibana, Fluentd
│   │   ├── values.yaml           # CI auto-updates image.tag here
│   │   └── charts/               # Subcharts (crm-app, mongodb are custom)
│   ├── argocd/                   # ArgoCD Application CRDs
│   ├── manifests/                # Plain K8s manifests (Ingress, ServiceMonitor, ExternalSecrets)
│   └── values/                   # Per-environment Helm value overrides
│
├── infra/                        # Terraform (AWS)
│   ├── eks.tf                    # EKS cluster + managed node group
│   ├── ecr.tf                    # Container registry (immutable tags)
│   ├── github-oidc.tf            # OIDC federation
│   ├── ebs-csi-driver.tf         # Persistent storage (gp3 default)
│   ├── secrets.tf                # AWS Secrets Manager + IRSA
│   ├── backend.tf                # S3 remote state
│   └── ARCHITECTURE.md
│
├── Makefile                      # Developer shortcuts (test, build, lint, plan)
└── CHANGELOG.md                  # Full change history across all phases
```

## Quick Start

### Prerequisites

- AWS CLI configured
- Terraform >= 1.10
- kubectl, Helm 3.x, Docker

### 1. Provision infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars

terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="region=YOUR_BUCKET_REGION"
terraform apply
```

### 2. Bootstrap the cluster

Run the **Bootstrap EKS Cluster** workflow from GitHub Actions (manual trigger). This installs ArgoCD, deploys initial services, and runs integration tests.

### 3. Ongoing deployments

Push to `app/` on `main`. CI builds, tests, scans, pushes to ECR, commits the new image tag. ArgoCD auto-syncs.

### 4. Local development

```bash
cd app && cp .env.example .env
docker compose up -d          # App at http://localhost:5000
pytest test_app.py -v         # 18 unit tests
./test_e2e.sh                 # 20 E2E tests (requires docker compose)
```

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Liveness check (process alive) |
| GET | `/ready` | Readiness check (DB connectivity) |
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

## License

MIT — see [LICENSE](LICENSE).

---

If you spot a pattern that's wrong here or a tradeoff I framed badly, I'd genuinely like to hear it — open an issue or reach out.
