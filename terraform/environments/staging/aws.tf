provider "aws" {
  region = local.aws_region
}

locals {
  aws_region  = "us-east-1"
  environment = "staging"

  vpc_name = "Staging"
  vpc_cidr = "10.0.0.0/16"
  num_azs  = 2
  azs      = slice(data.aws_availability_zones.available.names, 0, local.num_azs)

  ssh_keypair_name = "fz-staging"

  tags = {
    Terraform   = true
    Environment = local.environment
  }
}

################################################################################
# Networking
################################################################################

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = local.vpc_name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k + local.num_azs)]

  enable_ipv6                                    = true
  public_subnet_assign_ipv6_address_on_creation  = true
  private_subnet_assign_ipv6_address_on_creation = true

  public_subnet_ipv6_prefixes  = [0, 1]
  private_subnet_ipv6_prefixes = [2, 3]

  tags = local.tags
}

resource "aws_route" "private_nat_instance" {
  count = local.num_azs

  route_table_id         = element(module.vpc.private_route_table_ids, count.index)
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.aws_nat.primary_network_interface_id

  timeouts {
    create = "5m"
  }
}


################################################################################
# Compute
################################################################################

module "aws_bastion" {
  source = "../../modules/aws/bastion"

  ami  = data.aws_ami.ubuntu.id
  name = "bastion - ${local.environment}"

  associate_public_ip_address = true
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.staging.id
  vpc_security_group_ids = [
    module.sg_allow_all_egress.security_group_id,
    module.sg_allow_ssh_ingress.security_group_id
  ]
  subnet_id = element(module.vpc.public_subnets, 0)

  tags = local.tags
}

module "aws_nat" {
  source = "../../modules/aws/nat"

  ami  = data.aws_ami.ubuntu.id
  name = "nat - ${local.environment}"

  associate_public_ip_address = true
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.staging.id
  subnet_id                   = element(module.vpc.public_subnets, 0)

  vpc_security_group_ids = [
    module.sg_allow_all_egress.security_group_id,
    module.sg_allow_subnet_ingress.security_group_id
  ]

  tags = local.tags
}

module "aws_httpbin" {
  source = "../../modules/aws/httpbin"

  ami  = data.aws_ami.ubuntu.id
  name = "httpbin - ${local.environment}"

  associate_public_ip_address = false
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.staging.id
  subnet_id                   = element(module.vpc.private_subnets, 0)
  private_ip                  = cidrhost(element(module.vpc.private_subnets_cidr_blocks, 0), 100)

  vpc_security_group_ids = [
    module.sg_allow_all_egress.security_group_id,
    module.sg_allow_subnet_ingress.security_group_id
  ]

  tags = local.tags
}

module "aws_iperf" {
  source = "../../modules/aws/iperf"

  ami  = data.aws_ami.ubuntu.id
  name = "iperf - ${local.environment}"

  associate_public_ip_address = false
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.staging.id
  subnet_id                   = element(module.vpc.private_subnets, 0)
  private_ip                  = cidrhost(element(module.vpc.private_subnets_cidr_blocks, 0), 101)

  vpc_security_group_ids = [
    module.sg_allow_all_egress.security_group_id,
    module.sg_allow_subnet_ingress.security_group_id
  ]

  tags = local.tags
}

module "aws_gateway" {
  source = "../../modules/aws/gateway"

  ami  = data.aws_ami.ubuntu.id
  name = "gateway - ${local.environment}"

  associate_public_ip_address = false
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.staging.id
  subnet_id                   = element(module.vpc.private_subnets, 0)
  private_ip                  = cidrhost(element(module.vpc.private_subnets_cidr_blocks, 0), 50)

  vpc_security_group_ids = [
    module.sg_allow_all_egress.security_group_id,
    module.sg_allow_subnet_ingress.security_group_id
  ]

  # Gateway specific vars
  container_registry      = module.google-artifact-registry.url
  image_repo              = module.google-artifact-registry.repo
  image                   = "gateway"
  image_tag               = var.image_tag
  observability_log_level = "phoenix_channel=debug,firezone_gateway=debug,boringtun=debug,snownet=debug,str0m=info,connlib_gateway_shared=debug,firezone_tunnel=trace,connlib_shared=debug,warn"
  application_name        = "gateway"
  application_version     = replace(var.image_tag, ".", "-")
  api_url                 = "wss://api.${local.tld}"
  token                   = var.aws_gateway_token

  tags = local.tags
}

module "aws_coredns" {
  source = "../../modules/aws/coredns"

  ami  = data.aws_ami.ubuntu.id
  name = "coredns - ${local.environment}"

  associate_public_ip_address = false
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.staging.id
  subnet_id                   = element(module.vpc.private_subnets, 0)
  private_ip                  = cidrhost(element(module.vpc.private_subnets_cidr_blocks, 0), 10)

  application_name = "coredns"

  dns_records = [
    {
      name  = "gateway",
      value = module.aws_gateway.private_ip
    },
    {
      name  = "httpbin",
      value = module.aws_httpbin.private_ip
    },
    {
      name  = "iperf",
      value = module.aws_iperf.private_ip
    },
  ]

  vpc_security_group_ids = [
    module.sg_allow_all_egress.security_group_id,
    module.sg_allow_subnet_ingress.security_group_id
  ]

  tags = local.tags
}

################################################################################
# Security Groups
################################################################################

module "sg_allow_all_egress" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "allow all egress"
  description = "Security group to allow all egress"
  vpc_id      = module.vpc.vpc_id

  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  egress_with_ipv6_cidr_blocks = [
    {
      rule             = "all-all"
      ipv6_cidr_blocks = "::/0"
    },
  ]
}

module "sg_allow_subnet_ingress" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "allow ingress from subnet"
  description = "Security group to allow all ingress from other machines on the subnet"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = join(",", module.vpc.public_subnets_cidr_blocks)
    },
    {
      rule        = "all-all",
      cidr_blocks = join(",", module.vpc.private_subnets_cidr_blocks)
    }
  ]
}

module "sg_allow_ssh_ingress" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "allow SSH ingress from the internet"
  description = "Security group to allow SSH ingress from the internet"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH access from the internet"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
}

################################################################################
# SSH Keys
################################################################################

resource "aws_key_pair" "staging" {
  key_name   = "fz-staging"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBI0vUtLcJqkqIK7xRgfu68fLnP+x7r+W4Bs2bCUxq8F fz-staging-aws"

  tags = local.tags
}
