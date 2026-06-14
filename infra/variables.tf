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
  default     = ["us-east-1e"]
}

variable "ecr_force_destroy" {
  description = "Allow terraform destroy to delete the ECR repo even when it contains images (use -var='ecr_force_destroy=true' for teardown)"
  type        = bool
  default     = false
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

variable "github_bootstrap_environment" {
  description = "GitHub Actions environment name that gates assumption of the bootstrap role (configure required reviewers / branch protection on this environment in the GitHub UI)"
  type        = string
  default     = "production"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public endpoint. REQUIRED — no default. Set to your VPN/office egress range (e.g. [\"203.0.113.0/24\"]) or to [\"0.0.0.0/0\"] if you knowingly want the API world-reachable."
  type        = list(string)
  # No default on purpose: forcing the operator to make an explicit
  # choice keeps the secure-by-default posture honest. A wide-open
  # 0.0.0.0/0 should be a conscious decision, not a silent fallback.

  validation {
    condition     = length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "Supply at least one CIDR. Use [\"0.0.0.0/0\"] only if you knowingly want a public EKS API endpoint."
  }
}

variable "developer_user_arn" {
  description = "IAM User or Role ARN for interactive kubectl access (optional)"
  type        = string
  default     = ""
  # Set via terraform.tfvars — do not commit real ARNs
}

variable "use_custom_vpc" {
  description = "Create a dedicated VPC with private subnets + single NAT gateway. Default: true (secure-by-default). Set to false explicitly to reuse the AWS default VPC for a faster, throwaway bootstrap."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR block for the custom VPC (only used when use_custom_vpc = true)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "app_namespace" {
  description = "Kubernetes namespace for the CRM application stack"
  type        = string
  default     = "crm"
}
