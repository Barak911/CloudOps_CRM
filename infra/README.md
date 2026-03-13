# CloudOps CRM Infrastructure

Terraform code for provisioning AWS infrastructure for the CRM application.

## Components

- **EKS Cluster** -- Kubernetes 1.31 with managed node groups (t3a.medium, ON_DEMAND), public endpoint (restrict via `cluster_endpoint_public_access_cidrs`)
- **ECR Repository** -- Container registry with immutable tags and scan-on-push
- **GitHub OIDC Role** -- CI/CD authentication via OIDC federation (cluster-admin for bootstrap; see README for production hardening)
- **EBS CSI Driver** -- Dynamic volume provisioning with gp3 StorageClass
- **Secrets Manager** -- MongoDB credentials with IRSA-backed ExternalSecrets Operator access
- **Default VPC** -- Public subnets (no NAT Gateway costs)

## Quick Start

```bash
# 1. Create S3 bucket for Terraform state (one-time)
aws s3api create-bucket --bucket YOUR_BUCKET --region YOUR_REGION \
  --create-bucket-configuration LocationConstraint=YOUR_REGION

# 2. Configure variables
cat > terraform.tfvars <<EOF
github_repo_owner  = "<your-github-username>"
developer_user_arn = "arn:aws:iam::<ACCOUNT_ID>:user/<username>"
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
github_repo_owner  = "<your-github-username>"
developer_user_arn = "arn:aws:iam::<ACCOUNT_ID>:user/<username>"
# cluster_name                       = "cloudops-eks-cluster"  # optional override
# aws_region                         = "us-east-1"             # optional override
# cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]    # restrict API access to your IP/VPN
# ecr_force_destroy                  = true                    # allow terraform destroy to delete ECR repo
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
| `ecr.tf` | ECR repository |
| `ebs-csi-driver.tf` | EBS CSI addon + gp3 StorageClass |
| `github-oidc.tf` | GitHub Actions IAM role + least-privilege policies |
| `secrets.tf` | AWS Secrets Manager + IRSA role for ExternalSecrets Operator |
| `provider.tf` | AWS and Kubernetes providers |
| `backend.tf` | S3 remote state backend |
| `variables.tf` | Input variables |
| `outputs.tf` | Output values |

## EKS Access

Terraform creates EKS Access Entries for:
1. **GitHub Actions OIDC role** -- `AmazonEKSClusterAdminPolicy` (required for bootstrap: CRD installs, namespace creation, Helm across namespaces). For day-2 CI, consider scoping to ECR push + namespace edit.
2. **Developer IAM user** -- `AmazonEKSClusterAdminPolicy` (full access for interactive debugging, optional via `developer_user_arn`)

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
