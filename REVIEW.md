# DevOps Employer-Style Review — CloudOps CRM

Date: 2026-03-13

I read the repo and reviewed infra, pipelines, and Kubernetes configs. I did **not** run tests or apply infra.

## Findings (ordered by severity)

1. **[P1] IRSA trust condition likely broken (EBS CSI role may not be assumable)**
   - The OIDC condition key is built using `replace(..., "/^(.*provider/)/", "")`. `replace` does literal substring replacement, not regex, so this will not strip the ARN prefix. The resulting condition key will be invalid, preventing the EBS CSI controller from assuming the role and causing PVC provisioning to fail. Use `replace` with the exact prefix string or `regexreplace`.
   - File: `infra/ebs-csi-driver.tf` (lines 45–46)

2. **[P1] MongoDB auth disabled by default**
   - Auth is off, meaning any pod in the cluster can access the database if it can reach the service. With no NetworkPolicies, this is a significant security gap for a production‑grade DevOps portfolio. Consider enabling auth by default and wiring credentials via Secrets (and rotating them).
   - File: `k8s/crm-stack/charts/mongodb/values.yaml` (lines 42–44)

3. **[P1] Ingresses are HTTP-only with TLS disabled**
   - TLS is commented out and `ssl-redirect` is set to `false` for CRM, Kibana, and Grafana. This exposes credentials and session cookies in clear text and would be a hard “no” for production. Add cert-manager + TLS, force redirect, and consider auth at the edge.
   - File: `k8s/manifests/crm-ingress.yaml` (lines 14–22)

4. **[P1] ArgoCD server is run in insecure mode**
   - `--insecure` disables TLS on the ArgoCD server. Combined with an HTTP ingress, this is a serious exposure for a control plane UI. Either terminate TLS at ingress and keep ArgoCD in secure mode or lock the ingress behind auth/VPN.
   - File: `k8s/values/argocd-values.yaml` (lines 5–7)

5. **[P2] Public EKS endpoint + default VPC subnets**
   - The cluster uses the default VPC and public endpoint access is enabled. That’s okay for a demo, but for a portfolio aimed at DevOps roles you want private subnets + restricted endpoint access (CIDR‑limited or private only) and a managed VPC with explicit routing/NAT.
   - File: `infra/eks.tf` (lines 1–42)

6. **[P2] CI role is effectively cluster-admin**
   - GitHub Actions gets broad AWS policies plus EKS access entries granting `AmazonEKSClusterAdminPolicy`. For production‑grade DevOps, you’d scope this down to the minimal actions needed (ECR push + ArgoCD sync or EKS describe + kubectl apply) and restrict via conditions.
   - File: `infra/github-oidc.tf` (lines 40–83)

7. **[P3] `prevent_destroy` on ECR conflicts with teardown narrative**
   - The cleanup workflow assumes you can fully destroy infra, but `prevent_destroy = true` will block `terraform destroy` on the ECR repository even after deleting images. Either document the exception clearly or make this conditional.
   - File: `infra/ecr.tf` (lines 13–15)

## Additional gaps (not tied to single lines)

- No NetworkPolicies: any pod can talk to MongoDB/Elasticsearch/ArgoCD/Grafana.
- No secrets encryption at rest (EKS KMS) or secret rotation story.
- Single replicas for key services, HPA disabled, no PDBs → poor availability story.
- No node autoscaling (Cluster Autoscaler / Karpenter) or multi‑AZ failure strategy.
- No edge auth for Kibana/Grafana/ArgoCD (basic auth, SSO, or OAuth2 proxy).

## Strengths (what looks good)

- Clear GitOps flow with ArgoCD, multi‑source Applications, and CI updating image tags.
- OIDC‑based GitHub Actions auth (no static AWS keys).
- Good CI coverage for unit + E2E and security scanning (Trivy + pip‑audit).
- Thoughtful observability stack: ServiceMonitor, Prometheus/Grafana, and Fluentd → ES/Kibana.
- Security contexts and read‑only FS for the app container are done right.
- Excellent bootstrap/cleanup workflows for a demo environment.

## Hiring signal (employer lens)

- This is a strong DevOps portfolio base. The GitOps pipeline, observability, and automated bootstrap flow are above entry‑level.
- The biggest blockers for a DevOps role are security posture and production hardening. Fixing TLS/auth, least privilege, and IRSA correctness would materially improve the signal.

## Suggested next steps (highest impact)

1. Fix IRSA trust policy (EBS CSI) and add EKS secrets encryption (KMS).
2. Enable TLS + auth at ingress (cert‑manager + OAuth2 proxy).
3. Enable MongoDB auth + NetworkPolicies.
4. Add HPA + PDB + node autoscaling story.

