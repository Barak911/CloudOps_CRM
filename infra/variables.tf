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
  description = "Allow terraform destroy to delete the ECR repo even when it contains images"
  type        = bool
  default     = true
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

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public endpoint (default: unrestricted for bootstrap, restrict after setup)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
  # After initial setup, set to your office/VPN CIDR in terraform.tfvars
}

variable "developer_user_arn" {
  description = "IAM User or Role ARN for interactive kubectl access (optional)"
  type        = string
  default     = ""
  # Set via terraform.tfvars — do not commit real ARNs
}
