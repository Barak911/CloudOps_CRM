# Architecture

Cloud-native CRM application deployed on AWS EKS with ArgoCD GitOps, enforced NetworkPolicies, signed images, and a full observability + alerting pipeline.

## Monorepo Structure

```
CloudOps_CRM/
├── app/          # Flask REST API + tests + Dockerfile
├── k8s/          # Helm charts, ArgoCD Applications, manifests
│   ├── crm-stack/    # Umbrella chart (CRM + MongoDB ReplicaSet + EFK)
│   ├── argocd/       # ArgoCD Application CRDs (multi-source)
│   ├── manifests/    # Plain K8s resources:
│   │                 #   Ingress, ServiceMonitor, PrometheusRule,
│   │                 #   NetworkPolicies, Karpenter NodePool/EC2NodeClass,
│   │                 #   ExternalSecrets template, dashboard ConfigMap
│   └── values/       # Helm value overlays, including the CI-owned
│                     # image-state.yaml (tag + sha256 digest)
├── infra/        # Terraform (EKS, ECR, IAM OIDC split, EBS CSI,
│                 # Karpenter, SQS, EventBridge, custom VPC, Secrets Manager)
├── docs/proof/   # Captures from a live bootstrap run
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
   MongoDB rs0   Elasticsearch  Prometheus -> Alertmanager
   (mongodb-0/1/2)    |             |             (routing tree:
                  Fluentd      PrometheusRule      severity -> receiver)
                 (DaemonSet)   (SLO burn-rate +
                                platform health)

   Karpenter (controller + NodePool) provisions spot capacity for
   workloads that don't fit on the managed node group baseline.

   VPC CNI runs with enableNetworkPolicy=true; default-deny per
   namespace + explicit allows are *enforced*.
```

**Components:**
- Nginx Ingress Controller — single NLB entry point (two replicas for HA)
- CRM App — Flask REST API (ClusterIP), instrumented for Prometheus + JSON logs
- MongoDB — 3-member StatefulSet with replica set `rs0`, pod anti-affinity by AZ, pre-shared keyfile, rs.initiate via idempotent Helm/ArgoCD-hook Job
- Elasticsearch — HTTPS, 5Gi EBS
- Kibana — log visualization via Ingress
- Fluentd — log collection DaemonSet
- Prometheus / Grafana / Alertmanager — `monitoring` namespace; Alertmanager has a real routing tree (severity → receiver, inhibit rules) with null receivers
- ArgoCD — GitOps deployment controller, multi-source Application
- Karpenter — `karpenter` namespace; NodePool + EC2NodeClass; spot-first AL2023, IMDSv2-only
- ExternalSecrets Operator — `external-secrets` namespace; IRSA-backed Secrets Manager sync
- cert-manager — `cert-manager` namespace; self-signed ClusterIssuer

## AWS Infrastructure

```
AWS Account
  Custom VPC (default — use_custom_vpc=true)
    Private subnets (3 AZs) + single NAT
    EKS Cluster (Kubernetes 1.31)
      Managed addons: vpc-cni (NetworkPolicy enabled),
                      coredns, kube-proxy
      Managed Node Group: 3 x t3a.medium (ON_DEMAND) — baseline
      Karpenter NodePool: spot-first, capped 32 vCPU / 64 GiB
      EBS CSI Driver -> gp3 StorageClass (encrypted)

  ECR Repository: crm-app (immutable tags, scan-on-push)

  GitHub OIDC Roles:
    - github-actions-bootstrap   (cluster-admin via EKS Access Entry,
                                  trust gated by environment:production)
    - github-actions-ci          (ECR push only, no cluster access,
                                  trust pinned to refs/heads/main)

  Karpenter:
    - Controller IRSA role (scoped EC2 + SQS + IAM:PassRole permissions)
    - Node IAM role + pre-created instance profile
    - EKS_LINUX access entry for the node role
    - SQS interruption queue + EventBridge rules
      (spot warnings, rebalance recommendations, scheduled health, state)

  Secrets Manager:
    - <cluster>/mongodb-credentials (root + app user)
    - IRSA role assumed by external-secrets-sa in the crm namespace
```

## CI/CD Pipelines

| Workflow | Trigger | Role assumed | Purpose |
|----------|---------|--------------|---------|
| `ci.yml` | Push to main (path: `app/**`, `k8s/**`, `infra/**`) | `AWS_CI_ROLE_ARN` (ECR push only) | Build, test, scan, push to ECR, **cosign sign + SBOM attest**, update `image-state.yaml` |
| `bootstrap-cluster.yml` | Manual `workflow_dispatch` | `AWS_BOOTSTRAP_ROLE_ARN` (cluster-admin, env-gated) | One-time EKS cluster bootstrap, ArgoCD takeover |
| `cleanup-deployment.yml` | Manual `workflow_dispatch` | `AWS_BOOTSTRAP_ROLE_ARN` | Teardown ArgoCD + Helm + K8s resources, verify AWS cleanup |

### GitOps Flow (ci.yml)

```
git push (app/) -> Build -> Unit Tests -> Docker Build -> Trivy Scan ->
E2E Tests -> Push to ECR -> Resolve @sha256 digest from ECR ->
cosign sign (keyless OIDC) -> syft SBOM -> cosign attest ->
Write tag + digest to k8s/values/image-state.yaml [skip ci] ->
ArgoCD detects change -> Pulls image by @sha256: digest
```

### Bootstrap Flow (bootstrap-cluster.yml)

```
Build + Push to ECR -> Install ArgoCD -> Install ExternalSecrets ->
Install cert-manager + self-signed ClusterIssuer ->
Install Karpenter (helm) + apply NodePool/EC2NodeClass ->
Pre-create ES + Kibana secrets (helm --no-hooks bootstrap of crm-stack) ->
Apply ArgoCD Application CRDs -> Wait for Sync+Healthy ->
Run integration tests (CRM API + observability)
```

The bootstrap workflow is intentionally procedural and one-shot; see the comment block at the top of `bootstrap-cluster.yml` for what it does and where the line is between bootstrap glue and platform that ArgoCD owns from t=0.

## Observability

### EFK Stack (Logging)

App / MongoDB / system logs → Fluentd DaemonSet → Elasticsearch (HTTPS) → Kibana

Log indices: `logs-*` with a 1-shard, 0-replica template seeded at bootstrap; JSON parsing via an `logs-generic` ingest pipeline.

### Prometheus / Grafana (Monitoring)

CRM `/metrics` → ServiceMonitor → Prometheus → Grafana
PrometheusRule (`crm/crm-app-rules`) → Alertmanager → routed by `severity` (page / ticket) into null receivers (stubs — swap for Slack/PagerDuty to go live)

Metrics: `flask_http_request_total`, `flask_http_request_duration_seconds_bucket`, `up{job="crm-app"}`

Alert groups:
- `crm-app.slo` — burn-rate (multi-window 5m+1h fast, 30m+6h slow), p95 latency SLO, target-down
- `crm-platform.health` — KubePodCrashLooping, PVCNearFull, MongoDBDown

## Network Policy

- VPC CNI managed addon runs with `enableNetworkPolicy=true` — policies are **enforced**, not documentation.
- `crm` namespace: default-deny (ingress + egress) + explicit allows for every known flow (crm-app↔mongodb, fluentd/kibana→ES, ES peer 9300, ingress-nginx→app/kibana, prometheus scrape, DNS egress).
- `monitoring` namespace: ingress-only default-deny + ingress allows for grafana / alertmanager. Egress is left open because the scrapers genuinely need broad cross-cluster egress.

## Security

- **OIDC federation** for GitHub Actions (no long-lived credentials); roles split into bootstrap (cluster-admin, `environment:production`-gated) and CI (ECR-only, `refs/heads/main`-pinned).
- **Pod hardening**: non-root container (`appuser`, uid 1000), `readOnlyRootFilesystem`, `runAsNonRoot`, drop `ALL` capabilities, `allowPrivilegeEscalation: false`.
- **EKS Access Entries** (not aws-auth ConfigMap); only the bootstrap role gets cluster-admin.
- **NetworkPolicies enforced** by VPC CNI (see above).
- **Immutable ECR tags** + scan-on-push + scan blocks CRITICAL/HIGH.
- **Encrypted EBS volumes** (KMS).
- **TLS** for Elasticsearch (auto-generated certs); cluster traffic intra-cluster.
- **Trivy** image scanning (pinned version) blocks CRITICAL/HIGH at CI.
- **Supply chain**: cosign keyless OIDC signing + SPDX-JSON SBOM attestation; deployment pulls by `@sha256:` digest (immutable reference). Next step would be admission verification via cosign policy controller / Kyverno.
- **Karpenter nodes**: AL2023 with **IMDSv2-only**, encrypted gp3 root, MetadataOptions `httpTokens=required`.
- **GitHub Actions** pinned to commit SHAs (no mutable tag refs).

## Cost Optimization

- Karpenter spot-first NodePool, capped at 32 vCPU / 64 GiB so a runaway scheduler can't blow up the bill.
- Single NLB via Nginx Ingress (vs per-service LB).
- t3a.medium baseline (AMD, cost-optimized).
- 7-day Karpenter node expiry rolls onto fresh AMIs without manual intervention.
- `cleanup-deployment.yml` + `terraform destroy` for full teardown when not in use.

The single NAT in the default custom VPC is a cost / availability tradeoff documented in [README.md → Production Hardening](../README.md#production-hardening) — multi-AZ NAT is the production answer.
