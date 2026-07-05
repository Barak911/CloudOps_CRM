# Karpenter — node autoscaling beyond the static managed node group.
#
# Architecture:
#   * The managed node group (eks.tf) stays as a baseline for system pods
#     (CoreDNS, kube-proxy, ArgoCD, ESO, etc.). Karpenter handles burst
#     capacity for application workloads.
#   * Karpenter controller runs in the cluster, assumes an IRSA role with
#     EC2 launch/terminate permissions, and watches Pending pods.
#   * New nodes assume the karpenter_node role and join the cluster via an
#     EKS access entry of type EC2_LINUX.
#   * Spot interruption (and other capacity events) flow through an SQS
#     queue; Karpenter drains and replaces nodes proactively.
#
# Cost note: Karpenter does not provision anything until a workload needs
# it. Idle cost is just the controller pod (~30m memory).

locals {
  karpenter_namespace       = "karpenter"
  karpenter_service_account = "karpenter"
}

# -----------------------------------------------------------------------------
# Node IAM role + instance profile (nodes Karpenter launches assume this)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume.json
  description        = "IAM role assumed by Karpenter-provisioned EKS worker nodes"

  tags = {
    project = "CloudOps_CRM"
    role    = "karpenter-node"
  }
}

# Same managed policies the managed node group's role uses, so Karpenter
# nodes have parity (CNI, ECR pull, worker, SSM for debugging).
resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}

# Access entry so Karpenter-launched nodes can join the cluster.
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  # The module's enable_cluster_creator_admin_permissions interacts oddly with
  # adding access entries outside the module; depends_on keeps ordering stable.
  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Controller IAM role (IRSA)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.karpenter_namespace}:${local.karpenter_service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume.json
  description        = "IAM role for the Karpenter controller (IRSA)"

  tags = {
    project = "CloudOps_CRM"
    role    = "karpenter-controller"
  }
}

# Karpenter controller permissions. Scoped where it's safe to scope, and
# left at "*" where Karpenter genuinely needs to discover unbounded resources
# (subnets, AMIs, instance types). See:
#   https://karpenter.sh/v1.1/reference/cloudformation/
resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller"
  description = "Karpenter controller policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CreateFleet / RunInstances touch many resource types — the call
        # only succeeds if every type the API needs is on the Resource list.
        # This is the canonical set per Karpenter's v1.1 CloudFormation template.
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Resource = [
          "arn:aws:ec2:*::image/*",
          "arn:aws:ec2:*::snapshot/*",
          "arn:aws:ec2:*:*:security-group/*",
          "arn:aws:ec2:*:*:subnet/*",
          "arn:aws:ec2:*:*:launch-template/*",
          "arn:aws:ec2:*:*:fleet/*",
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:network-interface/*",
          "arn:aws:ec2:*:*:spot-instances-request/*",
        ]
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
        ]
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Resource = [
          "arn:aws:ec2:*:*:fleet/*",
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:network-interface/*",
          "arn:aws:ec2:*:*:launch-template/*",
          "arn:aws:ec2:*:*:spot-instances-request/*",
        ]
        Action = "ec2:CreateTags"
      },
      {
        Sid      = "AllowMachineMigrationTagging"
        Effect   = "Allow"
        Resource = "arn:aws:ec2:*:*:instance/*"
        Action   = "ec2:CreateTags"
      },
      {
        Sid      = "AllowScopedDeletion"
        Effect   = "Allow"
        Resource = ["arn:aws:ec2:*:*:instance/*", "arn:aws:ec2:*:*:launch-template/*"]
        Action   = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
      },
      {
        Sid      = "AllowRegionalReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:DescribeAvailabilityZones",
          # Required since Karpenter 1.3 (capacity-reservation support) —
          # the controller reconciles reservations even when none are used.
          "ec2:DescribeCapacityReservations",
        ]
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Resource = "arn:aws:ssm:*:*:parameter/aws/service/*"
        Action   = "ssm:GetParameter"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = "pricing:GetProducts"
      },
      {
        Sid      = "AllowInterruptionQueueActions"
        Effect   = "Allow"
        Resource = aws_sqs_queue.karpenter_interruption.arn
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
      },
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Resource = aws_iam_role.karpenter_node.arn
        Action   = "iam:PassRole"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Resource = module.eks.cluster_arn
        Action   = "eks:DescribeCluster"
      },
      {
        Sid      = "AllowInstanceProfileActions"
        Effect   = "Allow"
        Resource = aws_iam_instance_profile.karpenter_node.arn
        Action = [
          "iam:GetInstanceProfile",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# -----------------------------------------------------------------------------
# Interruption queue (spot termination + scheduled events)
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    project = "CloudOps_CRM"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = [
          "events.amazonaws.com",
          "sqs.amazonaws.com",
        ]
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

# EventBridge rules forward EC2 events to the SQS queue. Karpenter watches
# the queue and reacts to spot interruption (~2 min warning), instance
# state changes, and scheduled maintenance.
resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each = {
    spot_interruption = {
      name        = "${var.cluster_name}-karp-spot-interruption"
      description = "EC2 spot instance interruption warnings"
      pattern = jsonencode({
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Spot Instance Interruption Warning"]
      })
    }
    rebalance_recommendation = {
      name        = "${var.cluster_name}-karp-rebalance"
      description = "EC2 spot instance rebalance recommendations"
      pattern = jsonencode({
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance Rebalance Recommendation"]
      })
    }
    scheduled_change = {
      name        = "${var.cluster_name}-karp-scheduled-change"
      description = "AWS scheduled maintenance events"
      pattern = jsonencode({
        source        = ["aws.health"]
        "detail-type" = ["AWS Health Event"]
      })
    }
    state_change = {
      name        = "${var.cluster_name}-karp-instance-state"
      description = "EC2 instance state transitions"
      pattern = jsonencode({
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance State-change Notification"]
      })
    }
  }

  name          = each.value.name
  description   = each.value.description
  event_pattern = each.value.pattern

  tags = {
    project = "CloudOps_CRM"
  }
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each = aws_cloudwatch_event_rule.karpenter_interruption
  rule     = each.value.name
  arn      = aws_sqs_queue.karpenter_interruption.arn
}

# -----------------------------------------------------------------------------
# Subnet + security-group tags Karpenter uses for discovery
# -----------------------------------------------------------------------------

# Karpenter discovers subnets via tag karpenter.sh/discovery=<cluster_name>.
# Tag the EKS cluster's security group (already created by the module) and
# the subnets used by the cluster.
resource "aws_ec2_tag" "karpenter_discovery_sg" {
  resource_id = module.eks.cluster_primary_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# Subnets vary by use_custom_vpc. Both branches use the same tag.
resource "aws_ec2_tag" "karpenter_discovery_subnets_default_vpc" {
  for_each    = var.use_custom_vpc ? toset([]) : toset(data.aws_subnets.default[0].ids)
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "karpenter_discovery_subnets_custom_vpc" {
  for_each    = var.use_custom_vpc ? toset(module.vpc[0].private_subnets) : toset([])
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

output "karpenter_controller_role_arn" {
  description = "IRSA role ARN for the Karpenter controller service account"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_name" {
  description = "Name of the IAM role Karpenter-provisioned nodes assume"
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_interruption_queue_name" {
  description = "Name of the SQS queue Karpenter watches for capacity events"
  value       = aws_sqs_queue.karpenter_interruption.name
}
