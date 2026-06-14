# Troubleshooting Guide

## EKS kubectl Access

**Problem:** `kubectl get nodes` returns "provide credentials"

**Solution:**
```bash
CLUSTER_NAME=<your-cluster-name>
AWS_REGION=<your-region>

# Get your IAM ARN and create access entry
PRINCIPAL_ARN=$(aws sts get-caller-identity --query Arn --output text)
aws eks create-access-entry --cluster-name $CLUSTER_NAME --region $AWS_REGION --principal-arn $PRINCIPAL_ARN
aws eks associate-access-policy --cluster-name $CLUSTER_NAME --region $AWS_REGION \
  --principal-arn $PRINCIPAL_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster

# Update kubeconfig and verify
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
kubectl get nodes
```

---

## Port Conflicts (Local Development)

**Problem:** Port 5000 in use on macOS (AirPlay Receiver)

**Solution:** The docker-compose files map to port 5001 externally. Access the API at `http://localhost:5001`.

---

## Docker Build Issues

**Problem:** `externally-managed-environment` error on macOS

**Solution:**
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

## ECR Authentication

**Problem:** Docker push fails with auth error

**Solution:**
```bash
aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
```

---

## GitHub Actions CI/CD

**Problem:** `eks:DescribeCluster` AccessDeniedException

**Solution:** The GitHub Actions IAM role needs both:
1. IAM policy with `eks:DescribeCluster` permission
2. EKS Access Entry with cluster admin policy

Both are configured automatically by `github-oidc.tf` and `eks.tf`.

### Required GitHub Secrets

| Secret | Value |
|--------|-------|
| `AWS_BOOTSTRAP_ROLE_ARN` | `terraform output github_actions_bootstrap_role_arn` (used by bootstrap-cluster.yml and cleanup-deployment.yml; gated by `environment:production`) |
| `AWS_CI_ROLE_ARN` | `terraform output github_actions_ci_role_arn` (used by ci.yml; ECR push only, trust scoped to `refs/heads/main`) |
| `EKS_CLUSTER_NAME` | Your EKS cluster name |

---

## Cost Management

Always destroy resources after testing:

```bash
# 1. Run cleanup-deployment.yml workflow first
# 2. Then destroy infrastructure
terraform destroy
```

EKS clusters incur hourly charges even when idle.
