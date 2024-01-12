provider "aws" {
  region = local.aws_region
}

locals {
  aws_region = "us-east-1"

  vpc_name = "Staging"
  vpc_cidr = "10.0.0.0/16"
  num_azs  = 2
  azs      = slice(data.aws_availability_zones.available.names, 0, local.num_azs)

  ssh_keypair_name = "fz-staging"

  tags = {
    Terraform   = true
    Environment = "staging"
  }
}

################################################################################
# Networking
################################################################################

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = local.vpc_name
  cidr = local.vpc_cidr

  enable_ipv6                                   = true
  public_subnet_assign_ipv6_address_on_creation = true

  private_subnet_enable_dns64                                   = false
  private_subnet_enable_resource_name_dns_aaaa_record_on_launch = false

  azs                         = local.azs
  public_subnets              = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  private_subnets             = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k + local.num_azs)]
  public_subnet_ipv6_prefixes = range(0, local.num_azs)

  tags = local.tags
}
