module "vpc" {
  count   = var.use_custom_vpc ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.all.names, 0, 3)
  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1), cidrsubnet(var.vpc_cidr, 4, 2)]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 4), cidrsubnet(var.vpc_cidr, 4, 5), cidrsubnet(var.vpc_cidr, 4, 6)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter's EC2NodeClass discovers subnets by this tag. It MUST be set
    # here, through the module — a standalone aws_ec2_tag on module-managed
    # subnets loses a tag war: the module owns the subnets' tag set and
    # reverts out-of-band tags on the next apply (observed live: NodeClass
    # went SubnetsReady=False mid-bootstrap when the tag vanished).
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = {
    project                                     = "CloudOps_CRM"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# AZs data source for custom VPC (always available, filtered by opt-in status)
data "aws_availability_zones" "all" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
