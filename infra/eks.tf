data "aws_vpc" "default" { default = true }

# Dynamically discover AZs that support EKS (works in any region)
# Some AZs (e.g. us-east-1e) don't support EKS control planes —
# set var.excluded_availability_zones to skip them
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
  exclude_names = var.excluded_availability_zones
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_availability_zones.available.names
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Use self-managed addons bootstrapped on nodes (simpler, avoids dependency issues)
  bootstrap_self_managed_addons = true

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # expose API publicly so kubectl works outside VPC (restrict CIDRs in terraform.tfvars)
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  eks_managed_node_groups = {
    default = {
      desired_size   = 2
      max_size       = 2
      min_size       = 1
      instance_types = ["t3a.medium"]
      capacity_type  = "ON_DEMAND"
    }
  }

  tags = { project = "CloudOps_CRM" }

  # Enable cluster access management
  enable_cluster_creator_admin_permissions = true

  # Grant access to additional IAM principals
  access_entries = merge(
    {
      # GitHub Actions role — cluster-admin is required because bootstrap-cluster.yml
      # needs to: create namespaces, install CRDs (ArgoCD Application), Helm install
      # across argocd/monitoring/ingress-nginx/default namespaces.
      # For production, use separate IAM roles per workflow with tighter scoping.
      github_actions = {
        principal_arn = aws_iam_role.github_actions.arn
        type          = "STANDARD"
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    },
    # Developer user access (only created when developer_user_arn is provided)
    var.developer_user_arn != "" ? {
      developer = {
        principal_arn = var.developer_user_arn
        type          = "STANDARD"
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    } : {}
  )

  # Ensure IAM role is created before cluster access entries
  depends_on = [aws_iam_role.github_actions]
}
