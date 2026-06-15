# CloudOps CRM Infrastructure

Terraform code for provisioning AWS infrastructure for the CRM application.

## Components

- **EKS Cluster** -- Kubernetes 1.31 with managed node groups (t3a.medium, ON_DEMAND), public endpoint (restrict via `cluster_endpoint_public_access_cidrs`)
- **Custom VPC** -- Private subnets across 3 AZs + single NAT (default-on; set `use_custom_vpc=false` to fall back to the AWS default VPC)
- **ECR Repository** -- Container registry with immutable tags and scan-on-push
- **GitHub OIDC Roles (split)** -- `github-actions-bootstrap` (cluster-admin, env-gated) and `github-actions-ci` (ECR push only, refs/heads/main-pinned)
- **EBS CSI Driver** -- Dynamic volume provisioning with gp3 StorageClass
- **Secrets Manager** -- MongoDB root + app-scoped credentials with IRSA-backed ExternalSecrets Operator access
- **Karpenter infra** -- Controller IRSA, node IAM, SQS interruption queue, EventBridge rules
- **Substrate Helm releases** -- ArgoCD, ExternalSecrets, cert-manager, Karpenter, nginx-ingress, installed by Terraform via the wait-Job pattern

## Quick Start

```bash
# 1. Create S3 bucket for Terraform state (one-time)
aws s3api create-bucket --bucket YOUR_BUCKET --region YOUR_REGION \
  --create-bucket-configuration LocationConstraint=YOUR_REGION

# 2. Configure variables
cat > terraform.tfvars <<EOF
github_repo_owner                    = "<your-github-username>"
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # required; restrict for prod
EOF

# 3. Deploy
terraform init \
  -backend-config="bucket=YOUR_BUCKET" \
  -backend-config="region=YOUR_REGION"
terraform plan
terraform apply

# 4. Connect to cluster
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) \
  --region $(terraform output -raw aws_region)
kubectl get nodes
```

## Configuration

Create a `terraform.tfvars` file (gitignored):

```hcl
# Required (no defaults)
github_repo_owner                    = "<your-github-username>"
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # restrict for real prod

# Optional overrides (defaults shown)
# cluster_name        = "cloudops-eks-cluster"
# aws_region          = "us-east-1"
# use_custom_vpc      = true
# developer_user_arn  = ""                            # leave empty: cluster creator already has admin
# ecr_force_destroy   = true                          # allow terraform destroy to delete ECR repo
```

### Key Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Kubernetes Version | 1.31 | EKS cluster version |
| Node Instance Type | t3a.medium | Cost-optimized |
| Capacity Type | ON_DEMAND | Reliable availability |
| Node Scaling | 1-2 nodes | Auto-scaling range |
| StorageClass | gp3 (default) | Encrypted EBS volumes |
| Public Endpoint CIDRs | 0.0.0.0/0 | Restrict after initial setup |
| ECR Force Destroy | false | Set true for cleanup workflow |

## Files

| File | Description |
|------|-------------|
| `eks.tf` | EKS cluster and node groups |
| `vpc.tf` | Custom VPC (private subnets + single NAT; default-on) |
| `ecr.tf` | ECR repository |
| `ebs-csi-driver.tf` | EBS CSI addon + gp3 StorageClass |
| `github-oidc.tf` | GitHub Actions IAM role + least-privilege policies |
| `secrets.tf` | AWS Secrets Manager + IRSA role for ExternalSecrets Operator |
| `karpenter.tf` | Karpenter controller IRSA + node IAM + SQS interruption queue + EventBridge rules |
| `helm_releases.tf` | Substrate Helm charts (nginx-ingress, ArgoCD, ExternalSecrets, cert-manager, Karpenter) with in-cluster wait Jobs |
| `wait_gates.tf` | Shared SA / ClusterRole / Binding for the wait-Job pattern |
| `argocd_bootstrap.tf` | Chicken-and-egg manifests: crm namespace, AWS SecretStore binding, root App-of-Apps |
| `cleanup.tf` | Pre-destroy NLB drain (avoids orphaned NLBs on `terraform destroy`) |
| `provider.tf` | AWS, Kubernetes, Helm, kubectl providers |
| `versions.tf` | Terraform + provider version constraints |
| `backend.tf` | S3 remote state backend |
| `variables.tf` | Input variables |
| `outputs.tf` | Output values |

> The wait-Job pattern in `helm_releases.tf` + `wait_gates.tf` is how this repo avoids `helm_release { wait = true }` holding the terraform state lock for 15+ minutes across the substrate. See [ARCHITECTURE.md → Wait-Job pattern](ARCHITECTURE.md#wait-job-pattern-out-of-process-readiness-barrier).

## EKS Access

Terraform creates EKS Access Entries for:
1. **GitHub Actions OIDC role** -- `AmazonEKSClusterAdminPolicy` (required for bootstrap: CRD installs, namespace creation, Helm across namespaces). Day-2 CI only uses ECR push — ArgoCD handles all cluster operations.
2. **Developer IAM user** -- `AmazonEKSViewPolicy` (cluster-wide read) + `AmazonEKSEditPolicy` (scoped to crm, monitoring, argocd namespaces)

## Secrets Management

MongoDB credentials are stored in AWS Secrets Manager and synced to Kubernetes via the ExternalSecrets Operator:

1. `secrets.tf` creates the Secrets Manager secret and seeds it with a generated password
2. An IRSA role allows the ExternalSecrets service account to read the secret
3. `k8s/manifests/external-secrets.yaml` defines the `SecretStore` and `ExternalSecret` resources
4. The MongoDB chart references the externally-managed `mongodb-credentials` K8s Secret

For local development, bypass ExternalSecrets with:
```bash
helm install crm-stack ./k8s/crm-stack \
  --set mongodb.auth.existingSecret="" \
  --set mongodb.auth.rootPassword=localdev123
```

## Cleanup

**Run the cleanup-deployment workflow before destroying:**

```bash
# 1. Run cleanup-deployment.yml in GitHub Actions (removes K8s resources + ECR images)
# 2. Wait 2-3 minutes for AWS resource propagation
# 3. Destroy infrastructure (ecr_force_destroy allows ECR repo deletion)
terraform destroy -var="ecr_force_destroy=true"
```

This prevents orphaned Load Balancers and ECR deletion failures.

## Troubleshooting

**Can't connect to cluster:** `aws eks update-kubeconfig --name <cluster-name> --region <region>` then verify with `aws sts get-caller-identity`

**PVCs stuck Pending:** Check `kubectl get storageclass` -- gp3 should be default. If missing, run `terraform apply`.

**Node group DEGRADED:** Check node group status in AWS console. Switch to ON_DEMAND if using SPOT.
