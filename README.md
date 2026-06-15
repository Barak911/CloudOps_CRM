# CloudOps CRM

**A GitOps platform on AWS EKS — personal portfolio project exercising production-style DevOps patterns end-to-end.**

Single-developer learning project built to practice the full platform-engineering stack in one repo: Terraform infrastructure, GitHub Actions CI with AWS OIDC, ArgoCD-managed delivery, observability, signed images, and secrets management. It exercises the patterns; it is not a production deployment of them.

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
job=crm-app pod=crm-app-...  health=up
job=crm-app pod=crm-app-...  health=up

# MongoDB replica set across 3 nodes (anti-affinity by AZ):
mongodb-0   Running   ip-172-31-6-80.ec2.internal     us-east-1c   PRIMARY
mongodb-1   Running   ip-172-31-66-79.ec2.internal    us-east-1f   SECONDARY
mongodb-2   Running   ip-172-31-24-152.ec2.internal   us-east-1a   SECONDARY

# Karpenter provisioned a spot node from a Pending pod in ~60s:
ip-172-31-45-216.ec2.internal   karpenter-default   spot   c7a.medium   us-east-1b

# Workloads:
crm         8 pods Running    # crm-app x2, mongodb x3, ES, kibana, fluentd x3
monitoring  8 pods Running    # prometheus, alertmanager, grafana, kube-state, ...
argocd      5 pods Running
external-secrets  3 pods Running
cert-manager  3 pods Running
ingress-nginx 1 pod  Running
karpenter   2 pods Running
```

All workloads green on a fresh cluster brought up by the bootstrap workflow; raw captures are in [`docs/proof/`](docs/proof/).

## Scope & Intent

Built to answer one question: *can I run a real-feeling delivery pipeline solo, in a single AWS account, without papering over the hard parts?*

The patterns implemented here are the ones I'd reach for in a production environment. The **scope** is deliberately personal-account-sized — see [Out of Scope](#out-of-scope-intentionally), [Design Tradeoffs](#design-tradeoffs), and [Production Hardening](#production-hardening) below for the line between "pattern" and "fully-hardened production."

## Out of Scope (intentionally)

- Cross-region disaster recovery
- Separate dev / staging / prod clusters
- Real DNS + ACM-issued TLS (uses self-signed ClusterIssuer)
- On-call rotation, runbooks, paging integration (alerts are wired but receivers are nulls)
- Volume snapshots / Velero backups with a tested restore drill
- Multi-tenant namespace isolation (the NetworkPolicies are written for the workloads in this repo, not for arbitrary tenants)

Each of these is a real, distinct engineering problem. Half-implementing them as portfolio decoration would be misleading; documenting that I know they're missing is the honest version.

## Design Tradeoffs

Personal-account practicality drives a few defaults I'd flip for real production:

- **Public EKS API endpoint** — simplifies bootstrap from a laptop and GitHub-hosted runners. `cluster_endpoint_public_access_cidrs` is now a **required** variable with no default and a length-check validation, so a wide-open `0.0.0.0/0` is a conscious choice (and clearly visible in `terraform.tfvars`), not a silent fallback. In real prod: restrict to known CIDRs or disable public access entirely.
- **Single cluster** — one EKS cluster serves everything. Separate dev / staging / prod clusters are the obvious production answer.
- **Self-signed TLS** — cert-manager issues a working cert; browsers warn. Swap to Let's Encrypt or ACM + Route53 + a real domain for prod.
- **Karpenter NodePool capped at 32 vCPU / 64 GiB** — bursts beyond the baseline managed node group come from spot, but capped so a runaway scheduler can't blow up the bill. Lift the cap when there's a real budget.
- **Manual bootstrap workflow** — one-time imperative install of ArgoCD, ExternalSecrets Operator, cert-manager, and Karpenter, after which ArgoCD adopts everything. The chicken-and-egg of "GitOps for the GitOps controller" is an honest boundary, not a gap. At org scale this would become an App-of-Apps root with a thin install script; for a single-cluster, single-developer project the abstraction would cost more than it earns. The bootstrap workflow is annotated at the top with what it does and where the line is — see [.github/workflows/bootstrap-cluster.yml](.github/workflows/bootstrap-cluster.yml).

## What This Project Implements

The patterns below are the substance. Each one is end-to-end, not stubbed.

- **Infrastructure-as-code** for the full AWS footprint — EKS + 3 managed addons (VPC CNI with network-policy enforcement, CoreDNS, kube-proxy), ECR (immutable tags), IAM/OIDC, EBS CSI, S3 remote state, Secrets Manager, Karpenter (controller IRSA, node IAM, interruption SQS + EventBridge rules) — in `infra/`
- **OIDC federation with role split** — `github-actions-bootstrap` (cluster-admin, trust gated by GitHub `environment:production`) and `github-actions-ci` (ECR push only, trust pinned to `refs/heads/main`). No long-lived keys, no day-2 cluster access from CI.
- **GitOps delivery with ArgoCD** — multi-source Application reads the umbrella chart + a dedicated `image-state.yaml`. Day-2 CI never touches the cluster.
- **Helm umbrella chart** packaging the app, the MongoDB ReplicaSet, and the EFK stack as a single unit with shared config
- **MongoDB HA** — 3-member ReplicaSet across AZs with pod anti-affinity, pre-shared keyfile for member auth, and an idempotent Helm/ArgoCD-hook Job that runs `rs.initiate()` and provisions the app-scoped user. PyMongo gets a multi-host URI with `?replicaSet=rs0`.
- **Karpenter** for burst capacity — spot-first AL2023 with IMDSv2-only, encrypted gp3 root, soft AZ anti-affinity, 7-day node expiry, consolidation. Live test: a Pending pod triggered a spot c7a.medium in ~60s. Managed node group stays as the baseline for system pods.
- **Default-deny NetworkPolicies** — VPC CNI runs with `enableNetworkPolicy=true` so policies are *enforced*, not documentation. Default-deny in `crm` (ingress+egress), ingress-default-deny in `monitoring`, with explicit allows for every real flow.
- **Observability with real alerts** — Prometheus + Grafana with a ServiceMonitor for the app, Fluentd → Elasticsearch → Kibana for logs. `PrometheusRule` with Google SRE multi-window burn-rate alerts on a 99% SLO, p95 latency, target-down, crashloop, PVC-near-full, MongoDB-down. Alertmanager routing tree is real (severity → receiver, inhibit rule for the down→burn dependency); receivers are null stubs for this portfolio deployment — swap one for a Slack webhook to go live.
- **Secrets management** — AWS Secrets Manager + ExternalSecrets Operator via IRSA. No secrets in Git, no static AWS keys in the cluster. App gets a least-privilege DB user, not root.
- **Supply chain** — Trivy + pip-audit gate the build. cosign keyless OIDC signs every pushed image and attaches an SPDX-JSON SBOM (syft) as an attestation. Deployment pulls by `@sha256:` digest; tag is informational only.
- **Pod-level hardening** — `readOnlyRootFilesystem`, `runAsNonRoot`, dropped capabilities, no privilege escalation
- **Teardown workflow** — full destroy path, because building without tearing down isn't really infrastructure-as-code

## A note on the Flask app

The Python/Flask CRM in [`app/`](app/) is a deliberately thin payload — its only job is to be a real workload for the platform: it exposes Prometheus metrics, logs as JSON for the EFK pipeline, uses an IRSA-fetched MongoDB credential, has a readiness probe that hits the database, and routes uncaught exceptions through a centralized error handler that logs internally with a correlation ID and returns a generic 500 (no `str(e)` leakage). Authentication, schema validation, and rate-limiting are intentionally out of scope; the focus is on the surrounding platform, not the application.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Application** | Python Flask REST API, Gunicorn, MongoDB ReplicaSet |
| **Containers** | Docker (multi-stage builds), Amazon ECR (immutable tags) |
| **Orchestration** | Kubernetes (AWS EKS 1.31), Helm umbrella chart |
| **GitOps** | ArgoCD (multi-source App) |
| **CI/CD** | GitHub Actions with AWS OIDC federation, split bootstrap/CI roles |
| **Infrastructure** | Terraform (EKS, ECR, IAM OIDC, EBS CSI, Karpenter, SQS, EventBridge, Secrets Manager) |
| **Autoscaling** | Karpenter (NodePool + EC2NodeClass, spot-first, SQS interruption) |
| **Networking** | Nginx Ingress Controller + single AWS NLB; VPC CNI with NetworkPolicy enforcement |
| **Monitoring** | Prometheus, Grafana, ServiceMonitor + PrometheusRule (SLO burn-rate + platform health), Alertmanager routing |
| **Logging** | Fluentd (DaemonSet) → Elasticsearch → Kibana |
| **Secrets** | AWS Secrets Manager + ExternalSecrets Operator (IRSA) |
| **Supply chain** | cosign keyless OIDC signing, syft SBOM attestation, image digest pinning, Trivy + pip-audit |
| **Security** | Pod security contexts, read-only root FS, app-scoped DB credentials, IMDSv2-only on Karpenter nodes |

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
                     |  cosign sign + SBOM   |
                     |  Write image-state.   |
                     |    yaml [skip ci]     |
                     +-----------+-----------+
                                 |
                       commit on main (state file only)
                                 |
                                 v
                     +-----------+-----------+
                     |       ArgoCD          |
                     |  Detects Git change   |
                     |  Pulls by @sha256:    |
                     |    digest             |
                     +-----------+-----------+
                                 |
                                 v
     +-----------------------------------------------------------+
     |                    AWS EKS Cluster                        |
     |                                                           |
     |   Nginx Ingress Controller (single NLB)                   |
     |     /          ->  CRM Flask App  <->  MongoDB rs0        |
     |     /kibana    ->  Kibana                                 |
     |     /grafana   ->  Grafana                                |
     |     /argocd    ->  ArgoCD Dashboard                       |
     |                                                           |
     |   Fluentd (DaemonSet) -> Elasticsearch                    |
     |   Prometheus -> Grafana   (+ CRM ServiceMonitor)          |
     |   PrometheusRule -> Alertmanager (burn-rate + health)     |
     |                                                           |
     |   Managed node group (baseline) + Karpenter (burst)       |
     |   VPC CNI: NetworkPolicy enforced (default-deny)          |
     +-----------------------------------------------------------+
```

### GitOps flow

```
1. Developer pushes to app/             5. ArgoCD detects state-file change
2. CI builds, tests, scans, pushes      6. ArgoCD pulls image by @sha256: digest
3. CI signs (cosign) + attests SBOM     7. New version is live — zero manual steps
4. CI writes new tag+digest to
   k8s/values/image-state.yaml
```

**CI** owns: build, test, scan, ECR push, sign, SBOM, image-state update.
**CD (ArgoCD)** owns: every cluster operation after initial bootstrap.

The image-state file is segregated from the umbrella `values.yaml` so the only file the bot ever touches is one with no co-located mongodb/fluentd tags to clobber, and a workflow-level concurrency gate serializes simultaneous runs so the `git pull --rebase` window never collides with itself.

> **Bootstrap honesty.** The one-time `bootstrap-cluster.yml` workflow imperatively installs ArgoCD, ExternalSecrets Operator, cert-manager, and Karpenter so ArgoCD can adopt them afterward. "GitOps from absolute zero" requires bootstrapping the GitOps controller itself with something else — that's an honest boundary, not a gap.

## Key Decisions (and the alternatives I considered first)

A few choices that aren't obvious from the file tree.

### ArgoCD over `helm upgrade` from CI

The lazy path is `helm upgrade --install` in a GitHub Actions step. Works, fewer components to operate, most small projects use it.

I picked ArgoCD because cluster state then lives in Git, not in the last successful CI log. Drift is detected and self-healed, day-2 CI doesn't need kubectl credentials (and the OIDC trust can be locked down accordingly — see Key Decisions: Split IAM roles), and rollback is a one-line `git revert` that ArgoCD picks up automatically. The cost: one more controller to operate, multi-source App YAMLs that aren't obvious the first time you read them, and a slower iteration loop (you commit a value change to see it apply).

For a one-developer project the cost is real. I took it on because the GitOps muscle is the one I want to build, and the discipline of "if it's not in Git, it's not in the cluster" is worth more than the saved minutes.

### Split IAM roles + `environment:production` gate

The standard "OIDC role for GitHub Actions" pattern is one role trusted by `repo:owner/name:*` (every branch, every PR) with whatever permissions the broadest workflow needs. That's what this repo had originally — cluster-admin, repo-wide trust.

I split it into two: `github-actions-bootstrap` is cluster-admin but the OIDC trust is `repo:.../*:environment:production`, so the role can only be assumed by workflows that opt into the `production` GitHub environment (which itself can carry required-reviewer rules). `github-actions-ci` is ECR-push only, trust pinned to `refs/heads/main`, and has no EKS access entry at all — there is no path from day-2 CI to the cluster API.

Cost: one extra IAM role and a one-time `Settings → Environments` setup in GitHub. Benefit: a misconfigured PR cannot reach the cluster, and the bootstrap workflow's blast radius is fenced behind a gate that's visible in the GitHub UI.

### Karpenter alongside the managed node group, not instead of it

The pure-Karpenter setup (single NodePool, no managed node group) is elegant on paper. In practice the bootstrap workflow has to install Karpenter into *something*, and chicken-and-egg with system pods (CoreDNS, kube-proxy, the EBS CSI controller) is unpleasant.

The compromise: a 3-node managed node group carries the system pods + Karpenter controller itself, and a separate Karpenter NodePool handles burst capacity for application workloads. Spot-first with on-demand fallback, AL2023, IMDSv2-only, soft AZ anti-affinity, 7-day node expiry so I keep rolling onto fresh AMIs without manual intervention. The interruption SQS queue + EventBridge rules let Karpenter react to spot warnings before the kernel sends SIGTERM.

### NetworkPolicies that are actually enforced, not documentation

A `NetworkPolicy` resource is a no-op unless the CNI implements enforcement. The EKS default VPC CNI doesn't until you turn it on. I enable `enableNetworkPolicy=true` on the managed addon so the policies in `k8s/manifests/networkpolicies.yaml` are real iptables / eBPF rules, not aspirational YAML.

The model is default-deny per namespace (ingress + egress for `crm`, ingress-only for `monitoring` since the scrapers genuinely need broad egress), then explicit allows for each known flow. Two real misconfigurations got caught during rollout — the mongo-to-mongo replica replication needed an egress allow that wasn't obvious, and the init Job inherited `app=mongodb` so the same rule covered it.

### Monorepo

App, infra, and Kubernetes manifests live in one repo. The split-repo alternative is what most orgs end up with at scale — one team per repo, clean boundaries, separate CI.

At one-developer scale the coordination cost of split repos is higher than the blast-radius cost of a monorepo: atomic full-stack PRs ("add a new field, route, dashboard, and metric") are one commit, not three coordinated ones. At org scale I'd split.

### ExternalSecrets + IRSA, not sealed-secrets or sops

The two common alternatives encrypt secrets in Git. They work, they're simple to bootstrap, they avoid an external dependency.

I picked ExternalSecrets because *no version of a secret* lives in Git, even encrypted. Rotating a secret is a Secrets Manager UI operation, not a git push. IRSA means the cluster also has no static AWS credentials — workloads assume roles via their pod service-account identity.

Cost: another operator to install and operate, and a hard dependency on AWS Secrets Manager. For a portfolio project that cost is mostly setup time, paid once.

### Image digest pinning + cosign keyless signing

Every image is signed via cosign's keyless OIDC flow (identity = the GitHub Actions workflow that produced the image, recorded in Sigstore's Rekor transparency log) and an SPDX-JSON SBOM is attached as a cosign attestation. The deployment pulls the image by `@sha256:digest`, not by tag — the tag survives as a human-readable label, the digest is the canonical reference.

The alternatives — signing with a long-lived KMS-managed key, or just trusting `latest` — are common defaults. Keyless removes the "where do I store the signing key" question entirely. Digest pinning removes the "what does `tag:v1` actually point to right now?" question.

Cost: ~20 seconds added to each CI run for signing + SBOM generation, and an extra layer of artifacts in ECR (the signature + the attestation). Next step would be admission-time verification (cosign policy controller or Kyverno) so unsigned images can't run.

### Single Ingress + one NLB

Per-service load balancers are the easy default in EKS — every `Service` of type `LoadBalancer` gets its own NLB at ~$18/month before traffic.

One Nginx Ingress Controller behind a single NLB routes everything by path: cheaper, one TLS termination point to manage, easier mental model. Cost: the Ingress Controller becomes a SPOF and needs its own monitoring and upgrade discipline — manageable in practice with two replicas.

## Production Hardening

Everything in this table is a real production gap, not a stylistic preference. Current state is intentional for a personal-account portfolio; the recommendation is what I'd do for actual production.

| Area | Current State | Production Recommendation |
|------|--------------|--------------------------|
| EKS API endpoint | `cluster_endpoint_public_access_cidrs` is a required variable with no default (length-check validation); set to `0.0.0.0/0` in `tfvars` for this throwaway cluster | Restrict to known CIDRs; disable public access entirely once kubectl access moves to a bastion / SSM tunnel |
| VPC | Custom VPC by default (`use_custom_vpc=true`) with private subnets + a single NAT | Multi-AZ NAT (single NAT is a SPOF + cross-AZ data charges); VPC endpoints for ECR / S3 / Secrets Manager to keep egress cheap |
| IAM — CI | Split into bootstrap role (cluster-admin, trust gated by `environment:production`) and CI role (ECR push only, trust pinned to `refs/heads/main`, no cluster access entry) | Configure required reviewers on the `production` environment so a bootstrap run needs human approval; rotate the bootstrap role after each successful bring-up |
| TLS | cert-manager + self-signed `ClusterIssuer` | Let's Encrypt or ACM with Route53-validated cert, real domain |
| MongoDB HA | 3-member ReplicaSet, pod anti-affinity by AZ (soft), keyfile auth, rs.initiate via idempotent Helm/ArgoCD-hook Job, multi-host `?replicaSet=rs0` URI | Pin anti-affinity to *required* instead of preferred once the cluster spans 3+ AZs reliably; consider managed (DocumentDB / Atlas) to drop the rs.initiate Job entirely; add a `mongodb_exporter` so the `MongoDBDown` alert clears on healthy state instead of going `pending` |
| Observability | RED-method SLO burn-rate alerts (Google SRE multi-window) + platform health rules loaded into Prometheus; Alertmanager routing tree wired with severity routes and inhibit rules; receivers are null stubs | Real receiver (PagerDuty / Slack) on the `pager-null` route; SLO doc and runbooks linked from the `runbook_url` annotations |
| Network policy | Default-deny in `crm` and ingress-default-deny in `monitoring`, *enforced* by VPC CNI with `enableNetworkPolicy=true`; 14 explicit allows for every known flow | Per-tenant policies as the cluster gains tenants; an egress policy on the `kube-system` namespace itself |
| Autoscaling | Karpenter NodePool capped at 32 vCPU / 64 GiB, spot-first AL2023, IMDSv2-only, SQS interruption queue + EventBridge rules for spot warnings and rebalance recommendations | Split into multiple NodePools by workload class (system / app / batch); explicit on-demand fallback for PRIMARY-eligible MongoDB members |
| Supply chain | cosign keyless OIDC signs every pushed image; SPDX-JSON SBOM (syft) attached as a cosign attestation; deployment pulls by `@sha256:` digest | Admission-time signature verification (cosign policy controller or Kyverno) so unsigned images cannot run; require an attested SBOM on every deploy |
| Backups | None | Velero or scheduled EBS snapshots with a documented, *tested* restore procedure |
| Secrets rotation | Manual via Secrets Manager | Automated rotation Lambdas with downstream notification |

## Repository Structure

```
CloudOps_CRM/
├── .github/workflows/
│   ├── ci.yml                    # Day-2 CI: build, test, scan, sign, SBOM, push, image-state update
│   ├── bootstrap-cluster.yml     # One-time EKS cluster bootstrap (annotated)
│   └── cleanup-deployment.yml    # Full teardown workflow
│
├── app/                          # Flask CRM application (deliberately thin payload)
│   ├── app.py                    # REST API + global error handler + Prometheus metrics
│   ├── Dockerfile                # Multi-stage build
│   ├── test_app.py               # Unit tests (pytest)
│   ├── test_e2e.sh               # End-to-end test script
│   ├── requirements.txt
│   ├── requirements-dev.txt
│   └── docker-compose.test.yml   # E2E test environment
│
├── k8s/
│   ├── crm-stack/                # Helm umbrella chart
│   │   ├── Chart.yaml            # Dependencies: crm-app, mongodb, ES, Kibana, Fluentd
│   │   ├── values.yaml           # Static config; image fields overridden by image-state
│   │   └── charts/               # Subcharts (crm-app, mongodb are custom)
│   ├── argocd/                   # ArgoCD Application CRDs (multi-source)
│   ├── manifests/                # Plain K8s manifests applied via crm-manifests app
│   │   ├── crm-ingress.yaml
│   │   ├── crm-servicemonitor.yaml
│   │   ├── crm-dashboard-configmap.yaml
│   │   ├── crm-prometheusrules.yaml    # SLO burn-rate + platform health alerts
│   │   ├── networkpolicies.yaml        # Default-deny + explicit allows (enforced by VPC CNI)
│   │   ├── karpenter-nodepool.yaml     # EC2NodeClass + NodePool (envsubst'd at bootstrap)
│   │   └── external-secrets.yaml       # Rendered at bootstrap time
│   └── values/
│       ├── image-state.yaml      # CI-owned image tag + digest
│       └── ...                   # Per-environment overlays
│
├── infra/                        # Terraform (AWS)
│   ├── eks.tf                    # EKS cluster + managed addons + node group + access entries
│   ├── ecr.tf                    # Container registry (immutable tags, scan-on-push)
│   ├── github-oidc.tf            # Split bootstrap + CI roles, OIDC trust
│   ├── ebs-csi-driver.tf         # Persistent storage (gp3 default)
│   ├── secrets.tf                # Secrets Manager + ExternalSecrets IRSA
│   ├── karpenter.tf              # Karpenter IRSA + node IAM + SQS + EventBridge rules
│   ├── cleanup.tf                # Pre-destroy NLB drain (avoids orphaned NLBs)
│   ├── vpc.tf                    # Custom VPC (default-on)
│   ├── backend.tf                # S3 remote state (parameterized)
│   ├── ARCHITECTURE.md
│   ├── SETUP.md
│   └── TROUBLESHOOTING.md
│
├── docs/proof/                   # Captures from a live bootstrap run
└── Makefile                      # Developer shortcuts (test, build, lint, plan)
```

## Quick Start

### Prerequisites

- AWS CLI configured (your IAM principal becomes the cluster's first admin)
- Terraform >= 1.10
- kubectl, Helm 3.x, Docker
- `gh` CLI (for triggering the bootstrap workflow)

### 1. Provision infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — github_repo_owner and
# cluster_endpoint_public_access_cidrs are required.

terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="region=YOUR_BUCKET_REGION"
terraform apply
```

### 2. Wire up GitHub

```bash
REPO=YOUR_OWNER/CloudOps_CRM
gh api -X PUT /repos/$REPO/environments/production
terraform -chdir=infra output -raw github_actions_bootstrap_role_arn \
  | gh secret set AWS_BOOTSTRAP_ROLE_ARN --repo $REPO
terraform -chdir=infra output -raw github_actions_ci_role_arn \
  | gh secret set AWS_CI_ROLE_ARN --repo $REPO
echo "YOUR_CLUSTER_NAME" | gh secret set EKS_CLUSTER_NAME --repo $REPO
```

(Optional but recommended: add required reviewers to the `production` environment in GitHub's UI so a bootstrap run needs human approval.)

### 3. Bootstrap the cluster

Trigger the **Bootstrap EKS Cluster** workflow from GitHub Actions (manual `workflow_dispatch`). It installs ArgoCD, ExternalSecrets, cert-manager, Karpenter, applies the ArgoCD Application CRDs, then runs application + observability integration tests.

### 4. Ongoing deployments

Push to `app/` on `main`. CI builds, tests, scans, signs the image with cosign, attaches an SBOM, writes the new tag + `@sha256:` digest into `k8s/values/image-state.yaml`, and `[skip ci]` commits. ArgoCD auto-syncs.

### 5. Local development

```bash
cd app && cp .env.example .env
docker compose up -d          # App at http://localhost:5000
pytest test_app.py -v         # Unit tests
./test_e2e.sh                 # E2E tests (requires docker compose)
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

## License

MIT — see [LICENSE](LICENSE).

---

If you spot a pattern that's wrong here or a tradeoff I framed badly, I'd genuinely like to hear it — open an issue or reach out.
