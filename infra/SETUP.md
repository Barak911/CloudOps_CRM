# EKS Infrastructure Setup Guide

## Prerequisites

- AWS CLI installed and configured
- Terraform v1.10+
- kubectl installed

## Setup Steps

### 1. Configure AWS Credentials

```bash
aws configure --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

### 2. Create State Bucket

Create an S3 bucket for Terraform state (one-time, any region):

```bash
aws s3api create-bucket --bucket YOUR_BUCKET_NAME --region YOUR_REGION \
  --create-bucket-configuration LocationConstraint=YOUR_REGION
aws s3api put-bucket-versioning --bucket YOUR_BUCKET_NAME \
  --versioning-configuration Status=Enabled
```

### 3. Prepare Variables

Create `terraform.tfvars`:

```hcl
github_repo_owner  = "<your-github-username>"
developer_user_arn = "arn:aws:iam::<ACCOUNT_ID>:user/<username>"
# cluster_name     = "cloudops-eks-cluster"  # optional override
# aws_region       = "us-east-1"             # optional override
```

### 4. Deploy

```bash
terraform init \
  -backend-config="bucket=YOUR_BUCKET_NAME" \
  -backend-config="region=YOUR_BUCKET_REGION"
terraform plan
terraform apply
```

### 4. Connect to Cluster

```bash
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) \
  --region $(terraform output -raw aws_region)
kubectl get nodes
```

## Access Control

Terraform creates EKS Access Entries for:
1. **Developer user** -- from `developer_user_arn` variable
2. **`github-actions-bootstrap`** -- cluster-admin, used only by the manual bootstrap and cleanup workflows
3. **`github-actions-ci`** -- *no* access entry. Day-2 CI does not touch the cluster; ArgoCD owns deployment.

- **Developer user** receives `AmazonEKSViewPolicy` cluster-wide and `AmazonEKSEditPolicy` scoped to the `crm`, `monitoring`, and `argocd` namespaces.
- **`github-actions-bootstrap`** receives `AmazonEKSClusterAdminPolicy`. Trust is restricted to the `production` GitHub Actions environment (see `var.github_bootstrap_environment`), so a misconfigured PR cannot assume it. Gate with required reviewers in the repo's `Settings -> Environments -> production`.
- **`github-actions-ci`** has ECR push only. Trust is restricted to `ref:refs/heads/main`.

## GitHub Actions Setup

1. Create the `production` environment in `Settings -> Environments` (add required reviewers / branch restrictions).
2. `terraform output github_actions_bootstrap_role_arn` -> add as repo secret `AWS_BOOTSTRAP_ROLE_ARN`.
3. `terraform output github_actions_ci_role_arn` -> add as repo secret `AWS_CI_ROLE_ARN`.
4. Add the cluster name to repo Settings -> Secrets -> `EKS_CLUSTER_NAME`.
5. If you fork or rename the repo, override `github_repo_owner` and `github_repo_name` in `terraform.tfvars`. The OIDC trust subjects are exact-match (no wildcards), so they must match exactly.

## Troubleshooting

**"User cannot list resource nodes":** Your IAM principal lacks an access entry. Run:
```bash
PRINCIPAL_ARN=$(aws sts get-caller-identity --query Arn --output text)
aws eks create-access-entry --cluster-name <cluster-name> --region <region> --principal-arn $PRINCIPAL_ARN
aws eks associate-access-policy --cluster-name <cluster-name> --region <region> \
  --principal-arn $PRINCIPAL_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

**State lock error:** `terraform force-unlock -force <LOCK_ID>`
