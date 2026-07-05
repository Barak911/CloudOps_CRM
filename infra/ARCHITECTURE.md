# Architecture

Cloud-native CRM application deployed on AWS EKS with ArgoCD GitOps, enforced NetworkPolicies, signed images, and a full observability + alerting pipeline.

## Monorepo Structure

```
CloudOps_CRM/
├── app/          # Flask REST API + tests + Dockerfile
├── k8s/          # Helm charts, ArgoCD Applications, manifests
│   ├── crm-stack/    # Umbrella chart (CRM + MongoDB ReplicaSet + EFK)
│   ├── argocd/       # Root App-of-Apps + child Applications
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
- MongoDB — 3-member StatefulSet with replica set `rs0`, pod anti-affinity by AZ, pre-shared keyfile, rs.initiate via idempotent ArgoCD Sync-hook Job (wave 0, internal polling loop replaces sync-wave ordering)
- Elasticsearch — HTTPS, 5Gi EBS
- Kibana — log visualization via Ingress
- Fluentd — log collection DaemonSet
- Prometheus / Grafana / Alertmanager — `monitoring` namespace; Alertmanager has a real routing tree (severity → receiver, inhibit rules) with null receivers
- ArgoCD — GitOps deployment controller; root App-of-Apps spawns crm-stack (single-source), crm-manifests (single-source), prometheus-stack (multi-source: external chart + local overlay)
- Karpenter — `karpenter` namespace; NodePool + EC2NodeClass; spot-first AL2023, IMDSv2-only
- ExternalSecrets Operator — `external-secrets` namespace; IRSA-backed Secrets Manager sync
- cert-manager — `cert-manager` namespace; self-signed ClusterIssuer

## AWS Infrastructure

```
AWS Account
  Custom VPC (default — use_custom_vpc=true)
    Private subnets (3 AZs) + single NAT
    EKS Cluster (Kubernetes 1.34)
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
| `bootstrap-cluster.yml` | Manual `workflow_dispatch` | `AWS_BOOTSTRAP_ROLE_ARN` (cluster-admin, env-gated) | Verify Terraform's bootstrap landed; seed Elasticsearch index template + ingest pipeline; run integration tests |
| `cleanup-deployment.yml` | Manual `workflow_dispatch` | `AWS_BOOTSTRAP_ROLE_ARN` | Teardown ArgoCD + Helm + K8s resources, verify AWS cleanup |

### GitOps Flow (ci.yml)

```
git push (app/) -> Build -> Unit Tests -> Docker Build -> Trivy Scan ->
E2E Tests -> Push to ECR -> Resolve @sha256 digest from ECR ->
cosign sign (keyless OIDC) -> syft SBOM -> cosign attest ->
Write tag + digest to k8s/values/image-state.yaml [skip ci] ->
ArgoCD detects change -> Pulls image by @sha256: digest
```

### Bootstrap Flow (`terraform apply`)

The platform is brought up by Terraform in one shot — no procedural shell scripts, no `helm install` lines in a workflow. The substrate charts (ArgoCD, ExternalSecrets, cert-manager, Karpenter, nginx-ingress) are `helm_release` resources, and the three chicken-and-egg manifests that bootstrap GitOps (crm namespace, AWS SecretStore binding, root App-of-Apps) are `kubectl_manifest` resources.

```
terraform apply
  └─ EKS cluster + VPC + IAM/OIDC + ECR + Secrets Manager + Karpenter infra
  └─ Helm releases (wait=false): nginx-ingress, ArgoCD, ExternalSecrets,
                                 cert-manager + ClusterIssuer, Karpenter
  └─ Wait Jobs (in-cluster `kubectl wait`) gate the dependents
  └─ Chicken-and-egg manifests: crm namespace, AWS SecretStore, root App
  └─ ArgoCD picks up root App, syncs crm-stack + crm-manifests + monitoring
  └─ Inside crm-stack: mongodb-replset-init Sync hook fires `rs.initiate()`
     and provisions the app user (idempotent)

bootstrap-cluster.yml (manual, post-apply)
  └─ Confirms ArgoCD root + children are Synced + Healthy
  └─ Seeds Elasticsearch logs-* index template + ingest pipeline
  └─ Runs CRM API + observability integration tests
```

#### Wait-Job pattern (out-of-process readiness barrier)

`helm_release { wait = true }` blocks INSIDE the terraform process and holds the state lock for the entire wait window. Across 5 substrate charts that's 15+ minutes of held lock — a single SIGKILL or network blip leaves a stale lock that needs manual `terraform force-unlock` recovery (real risk on a flaky laptop network — see [Flaky-network resilience](#flaky-network-resilience)).

With `wait = false` + a `kubernetes_job_v1` running `kubectl wait --for=condition=Available ...` in-cluster, each helm_release returns in seconds; the blocking work moves to Job resources whose readiness check runs *in-cluster*. The terraform state lock is held only briefly per resource.

```
helm_release.argocd  (wait=false, returns in ~10s)
        │
        ▼
kubernetes_job_v1.argocd_ready    ──── runs in-cluster ────►  argocd-server
   (kubectl wait --for=condition=Available deployment/argocd-server)         │
        │                                                                    │
        ▼ Job Succeeded ───── terraform unblocks ◄───────────  Available     ┘
        │
        ▼
kubectl_manifest.argocd_root_app  (depends_on the wait Job, not the helm release)
```

The pattern is from `lablabs/terraform-aws-eks-universal-addon` and is the convention modern eks-addon Terraform modules converge on. Implementation lives in `infra/wait_gates.tf` (shared SA + ClusterRole + Binding) and `infra/helm_releases.tf` (one Job per release).

#### Flaky-network resilience

The wait-Job refactor is what makes `terraform apply` from a laptop with intermittent WiFi safe. The terraform process is no longer parked on a 15-minute wait — it returns in seconds, the readiness check continues in-cluster, and on the next `apply` the Job is idempotent (terraform sees it Succeeded and moves on). Combined with `TF_REGISTRY_DISCOVERY_RETRY=10` + `TF_PLUGIN_CACHE_DIR` for the Terraform Registry's intermittent rate-limiting, the entire bring-up is interruption-tolerant.

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
