# AWS Secrets Manager — stores credentials consumed by ExternalSecrets Operator in EKS

resource "aws_secretsmanager_secret" "mongodb_credentials" {
  name                    = "${var.cluster_name}/mongodb-credentials"
  description             = "MongoDB root and application credentials for CRM stack"
  recovery_window_in_days = 0 # immediate deletion for clean destroy/re-apply cycles

  tags = {
    project = "CloudOps_CRM"
  }
}

# Seed the secret with a generated password on first apply.
# After creation, rotate the password in the AWS Console or via CI — Terraform
# will NOT overwrite an existing secret value thanks to the lifecycle ignore.
resource "random_password" "mongodb_root" {
  length  = 24
  special = false
}

resource "random_password" "mongodb_app" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret_version" "mongodb_credentials" {
  secret_id = aws_secretsmanager_secret.mongodb_credentials.id
  secret_string = jsonencode({
    username     = "admin"
    password     = random_password.mongodb_root.result
    app_username = "crm_app"
    app_password = random_password.mongodb_app.result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# IAM policy for ExternalSecrets Operator to read this secret
resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets"
  description = "Allow ExternalSecrets Operator to read Secrets Manager secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.mongodb_credentials.arn
      }
    ]
  })
}

# IRSA role for ExternalSecrets Operator service account
resource "aws_iam_role" "external_secrets" {
  name = "${var.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:${var.app_namespace}:external-secrets-sa"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    project = "CloudOps_CRM"
  }
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}
