variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "cloudops-eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.31"
}

variable "excluded_availability_zones" {
  description = "AZs to exclude from EKS (e.g. us-east-1e does not support EKS control plane)"
  type        = list(string)
  default     = []
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository"
  type        = string
  default     = "crm-app"
}

variable "github_repo_owner" {
  description = "GitHub username or org that owns the repo (for OIDC trust)"
  type        = string
  # Set via terraform.tfvars
}

variable "github_repo_name" {
  description = "GitHub repository name for OIDC trust (change if repo is renamed)"
  type        = string
  default     = "CloudOps_CRM"
}

variable "developer_user_arn" {
  description = "IAM User or Role ARN for interactive kubectl access (optional)"
  type        = string
  default     = ""
  # Set via terraform.tfvars — do not commit real ARNs
}
