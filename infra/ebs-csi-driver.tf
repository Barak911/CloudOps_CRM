# EBS CSI Driver Addon for EKS
# Required for dynamic provisioning of EBS volumes (PersistentVolumes)

# Data source to get AWS account ID
data "aws_caller_identity" "current" {}

# Default StorageClass using EBS CSI Driver with gp3 volumes
# This is required for PVCs to bind automatically (MongoDB, Elasticsearch, etc.)
resource "kubernetes_storage_class" "gp3_default" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi_driver]
}

# IAM role for EBS CSI Driver
resource "aws_iam_role" "ebs_csi_driver" {
  name = "AmazonEKS_EBS_CSI_DriverRole"

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
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "AmazonEKS_EBS_CSI_DriverRole"
    project = "CloudOps_CRM"
  }
}

# Attach the AWS managed policy for EBS CSI Driver
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Install EBS CSI Driver as an EKS addon
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.37.0-eksbuild.1" # Compatible with EKS 1.31
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  # Ensure the IAM role is created first
  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_driver,
    module.eks
  ]

  tags = {
    project = "CloudOps_CRM"
  }
}
