# GitHub OIDC Provider and Role for CI/CD

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo_owner}/${var.github_repo_name}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-ecr-eks"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
  description        = "Role for GitHub Actions to deploy to EKS"

  tags = {
    project = "CloudOps_CRM"
  }
}

# Attach necessary policies for GitHub Actions
resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "github_actions_eks_describe" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Custom policy for EKS access
resource "aws_iam_policy" "github_actions_eks" {
  name        = "github-actions-eks-access"
  description = "Allow GitHub Actions to interact with EKS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:DescribeNodegroup",
          "eks:ListNodegroups",
          "eks:AccessKubernetesApi",
          "eks:ListAccessEntries",
          "eks:DescribeAccessEntry",
          "eks:CreateAccessEntry",
          "eks:DeleteAccessEntry",
          "eks:ListAssociatedAccessPolicies",
          "eks:AssociateAccessPolicy",
          "eks:DisassociateAccessPolicy"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_eks_custom" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_eks.arn
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions OIDC role"
  value       = aws_iam_role.github_actions.arn
}
