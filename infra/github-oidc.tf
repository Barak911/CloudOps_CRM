# GitHub OIDC Provider and roles for CI/CD.
#
# Two distinct roles, by blast radius:
#
#   * github_actions_bootstrap — cluster-admin via EKS access entry. Used only
#     by the manual bootstrap-cluster.yml and cleanup-deployment.yml workflows.
#     Trust is restricted to runs against the "production" GitHub Actions
#     environment, which gates the workflow behind required reviewers /
#     wait timers / branch restrictions configured in the GitHub UI.
#
#   * github_actions_ci — day-2 ECR push only. No EKS access entry, no
#     cluster permissions. Trust is restricted to pushes on refs/heads/main.
#     ArgoCD owns all in-cluster deployment, so CI does not need cluster
#     access at all.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_repo_sub_prefix = "repo:${var.github_repo_owner}/${var.github_repo_name}"
}

# -----------------------------------------------------------------------------
# Bootstrap role: cluster-admin, gated by "production" environment
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_bootstrap_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_repo_sub_prefix}:environment:${var.github_bootstrap_environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions_bootstrap" {
  name               = "github-actions-bootstrap"
  assume_role_policy = data.aws_iam_policy_document.github_actions_bootstrap_assume.json
  description        = "GitHub Actions bootstrap/teardown - cluster-admin, gated by environment:${var.github_bootstrap_environment}"

  tags = {
    project = "CloudOps_CRM"
    role    = "bootstrap"
  }
}

# ECR push (needed because bootstrap builds + pushes the initial image)
resource "aws_iam_role_policy_attachment" "bootstrap_ecr" {
  role       = aws_iam_role.github_actions_bootstrap.name
  policy_arn = aws_iam_policy.github_actions_ecr_push.arn
}

# EKS DescribeCluster (for aws eks update-kubeconfig)
resource "aws_iam_role_policy_attachment" "bootstrap_eks" {
  role       = aws_iam_role.github_actions_bootstrap.name
  policy_arn = aws_iam_policy.github_actions_eks_describe.arn
}

# -----------------------------------------------------------------------------
# CI role: ECR push only, restricted to refs/heads/main
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_ci_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_repo_sub_prefix}:ref:refs/heads/main"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name               = "github-actions-ci"
  assume_role_policy = data.aws_iam_policy_document.github_actions_ci_assume.json
  description        = "GitHub Actions day-2 CI - ECR push only, trust scoped to refs/heads/main"

  tags = {
    project = "CloudOps_CRM"
    role    = "ci"
  }
}

resource "aws_iam_role_policy_attachment" "ci_ecr" {
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = aws_iam_policy.github_actions_ecr_push.arn
}

# -----------------------------------------------------------------------------
# Shared policies
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "github_actions_ecr_push" {
  name        = "github-actions-ecr-push"
  description = "Push images to the CRM ECR repo"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages"
        ]
        Resource = aws_ecr_repository.demo_crm.arn
      }
    ]
  })
}

resource "aws_iam_policy" "github_actions_eks_describe" {
  name        = "github-actions-eks-describe"
  description = "Describe the EKS cluster (for update-kubeconfig)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      }
    ]
  })
}
