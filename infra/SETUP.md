# EKS Infrastructure Setup Guide

## Prerequisites

- AWS CLI installed and configured
- Terraform v1.10+
- kubectl, Helm 3.x, Docker
- `gh` CLI (for the bootstrap workflow + setting GitHub secrets)

## Setup Steps

### 1. Configure AWS Credentials

```bash
aws configure --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

The IAM principal you configure here becomes the cluster's first cluster-admin via `enable_cluster_creator_admin_permissions = true` in `eks.tf`. No extra access entry needed for yourself.

### 2. Create State Bucket

Create an S3 bucket for Terraform state (one-time, any region):

```bash
aws s3api create-bucket --bucket YOUR_BUCKET_NAME --region YOUR_REGION \
  --create-bucket-configuration LocationConstraint=YOUR_REGION
aws s3api put-bucket-versioning --bucket YOUR_BUCKET_NAME \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket YOUR_BUCKET_NAME \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket YOUR_BUCKET_NAME \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

> Use a state-bucket region you reach reliably — terraform's long "wait for resource Ready" loops will fail if S3/STS DNS for the backend region blips. `us-east-1` is a safe default.

### 3. Prepare Variables

Create `terraform.tfvars` (gitignored):

```hcl
# Required
github_repo_owner                    = "<your-github-username>"
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # ← REQUIRED, no default

# Optional overrides (defaults shown)
# cluster_name                = "cloudops-eks-cluster"
# aws_region                  = "us-east-1"
# use_custom_vpc              = true   # secure-by-default; flip to false to reuse the AWS default VPC
# vpc_cidr                    = "10.0.0.0/16"
# github_bootstrap_environment = "production"
# developer_user_arn          = ""     # leave empty: cluster creator already has admin
```

**Required variables** with no default:
- `github_repo_owner` — your GitHub username/org. The OIDC trust subjects are exact-match.
- `cluster_endpoint_public_access_cidrs` — there is intentionally no default so an open `0.0.0.0/0` is a conscious choice and not a silent fallback. Set to your VPN/office egress range for a real cluster (e.g. `["203.0.113.0/24"]`); use `["0.0.0.0/0"]` only if you knowingly want a public API endpoint.

### 4. Deploy

```bash
terraform init \
  -backend-config="bucket=YOUR_BUCKET_NAME" \
  -backend-config="region=YOUR_BUCKET_REGION"
terraform plan
terraform apply
```

Plan creates ~120 resources (cluster, addons, node group, IAM, ECR, Karpenter infra, Secrets Manager, VPC). Expect 15–20 minutes total: ~10 minutes on the EKS control plane, ~5 on the managed node group, the rest in parallel.

### 5. Connect to Cluster

```bash
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) \
  --region $(terraform output -raw aws_region | awk '{print}')
kubectl get nodes
```

You should see 3 `t3a.medium` nodes Ready (the baseline managed node group).

### 6. Wire up GitHub

```bash
REPO=<your-owner>/CloudOps_CRM

# Create the production environment that gates the bootstrap role's OIDC trust
gh api -X PUT /repos/$REPO/environments/production
# (Optional but recommended: add required reviewers in Settings → Environments → production)

# Push role ARNs as repo secrets
terraform output -raw github_actions_bootstrap_role_arn | \
  gh secret set AWS_BOOTSTRAP_ROLE_ARN --repo $REPO
terraform output -raw github_actions_ci_role_arn | \
  gh secret set AWS_CI_ROLE_ARN --repo $REPO

# Cluster name (workflows read this for kubeconfig)
terraform output -raw cluster_name | \
  gh secret set EKS_CLUSTER_NAME --repo $REPO
```

### 7. Trigger the bootstrap workflow

```bash
gh workflow run bootstrap-cluster.yml --repo $REPO --ref main \
  --field aws_region=us-east-1 \
  --field cluster_name=$(terraform output -raw cluster_name)
```

The bootstrap workflow installs ArgoCD, ExternalSecrets Operator, cert-manager, Karpenter, applies the ArgoCD Application CRDs, then runs application + observability integration tests. Watch it run with `gh run watch` or in the GitHub Actions UI.

## Access Control

Terraform creates EKS Access Entries for:
1. **Cluster creator** — your IAM principal (via `enable_cluster_creator_admin_permissions = true`).
2. **`github-actions-bootstrap`** — `AmazonEKSClusterAdminPolicy`. Trust is restricted to the `production` GitHub Actions environment, so a misconfigured PR cannot assume it. Gate with required reviewers in the repo's `Settings → Environments → production`.
3. **`github-actions-ci`** — *no* access entry. Day-2 CI has ECR push only; ArgoCD owns deployment.
4. **`<cluster>-karpenter-node`** — `EC2_LINUX` access entry. Karpenter-launched nodes join the cluster via this.
5. **Developer user** — only if `developer_user_arn` is set; gets `AmazonEKSViewPolicy` cluster-wide + `AmazonEKSEditPolicy` on `crm`/`monitoring`/`argocd`. Optional — the cluster creator already has admin.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues (kubectl auth, state lock recovery, Karpenter instance-profile errors, NetworkPolicy debugging).

**State lock error during a flaky network:**
```bash
# Get the lock ID from the error message, then:
terraform force-unlock -force <LOCK_ID>
```

**Resumed apply finds an existing resource (e.g. cluster already exists after a DNS blip mid-apply):**
```bash
terraform import 'module.eks.aws_eks_cluster.this[0]' <cluster-name>
```
