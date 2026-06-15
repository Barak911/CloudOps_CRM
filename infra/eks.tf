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

  # Managed addons. VPC CNI runs in NetworkPolicy enforcement mode so the
  # NetworkPolicy resources in k8s/manifests/networkpolicies.yaml are real
  # network rules, not documentation. CoreDNS and kube-proxy are pinned by
  # the addon's "most_recent = true" — swap to a fixed version_string for
  # production-grade upgrade control.
  #
  # `before_compute = true` is load-bearing: without it, the managed node
  # group is created in parallel with the addons, and instances boot before
  # vpc-cni is installed → kubelet starts with no pod networking → nodes
  # never report Ready → node group times out at NodeCreationFailure after
  # 30+ minutes. With before_compute the module's internal dep-graph holds
  # the node group until the addons are ACTIVE.
  bootstrap_self_managed_addons = false

  cluster_addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
      # AmazonEKS_CNI_Policy is attached to the managed-node-group IAM role
      # by default, so no IRSA role is needed here.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
        }
      })
    }
    kube-proxy = {
      most_recent    = true
      before_compute = true
    }
    coredns = {
      # CoreDNS schedules ONTO nodes, so it can't be before_compute — it
      # needs a node to run on. Reaches ACTIVE shortly after the node group.
      most_recent = true
    }
  }

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

  # Grant access to additional IAM principals.
  #
  # Only the bootstrap role gets cluster-admin. Day-2 CI uses a separate
  # IAM role with ECR push only (see infra/github-oidc.tf) — it has no
  # access entry here and cannot reach the cluster API at all. ArgoCD
  # owns all in-cluster deployment via GitOps.
  access_entries = merge(
    {
      github_actions_bootstrap = {
        principal_arn = aws_iam_role.github_actions_bootstrap.arn
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
  depends_on = [aws_iam_role.github_actions_bootstrap]
}
