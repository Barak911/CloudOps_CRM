data "aws_vpc" "default" {
  count   = var.use_custom_vpc ? 0 : 1
  default = true
}

# Dynamically discover AZs that support EKS (works in any region)
# Some AZs (e.g. us-east-1e) don't support EKS control planes —
# set var.excluded_availability_zones to skip them
data "aws_availability_zones" "available" {
  count = var.use_custom_vpc ? 0 : 1
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
  exclude_names = var.excluded_availability_zones
}

data "aws_subnets" "default" {
  count = var.use_custom_vpc ? 0 : 1

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_availability_zones.available[0].names
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Use self-managed addons bootstrapped on nodes (simpler, avoids dependency issues)
  bootstrap_self_managed_addons = true

  vpc_id     = var.use_custom_vpc ? module.vpc[0].vpc_id : data.aws_vpc.default[0].id
  subnet_ids = var.use_custom_vpc ? module.vpc[0].private_subnets : data.aws_subnets.default[0].ids

  # expose API publicly so kubectl works outside VPC (restrict CIDRs in terraform.tfvars)
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  eks_managed_node_groups = {
    default = {
      desired_size   = 3
      max_size       = 3
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
      # GitHub Actions role — cluster-admin is required during bootstrap to create
      # namespaces, install CRDs (e.g. ArgoCD, ExternalSecrets), and run Helm
      # installs across multiple namespaces.  Day-2 CI does NOT need cluster
      # access because ArgoCD handles all in-cluster deployment via GitOps.
      # PRODUCTION NOTE: Create a separate day-2 CI role scoped only to ECR push
      # and remove this cluster-admin grant once bootstrap is complete.
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
          view = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
            access_scope = {
              type = "cluster"
            }
          }
          edit = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = {
              type       = "namespace"
              namespaces = ["crm", "monitoring", "argocd"]
            }
          }
        }
      }
    } : {}
  )

  # Ensure IAM role is created before cluster access entries
  depends_on = [aws_iam_role.github_actions]
}
