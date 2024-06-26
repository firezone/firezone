module "firezone_gateway_example" {
  # Required inputs
  source         = "github.com/firezone/firezone/terraform/modules/aws/nat-gateway"
  firezone_token = "YOUR_FIREZONE_TOKEN"
  base_ami       = "ami-0a640b520696dc6a8" # Ubuntu 22.04
  vpc            = aws_vpc.main.id
  public_subnet  = aws_subnet.public.id
  private_subnet = aws_subnet.private.id
  instance_security_groups = [
    aws_security_group.instance.id
  ]

  # Optional inputs
  # firezone_version    = "latest"
  # firezone_api_url    = "wss://api.firezone.dev"
  # instance_type       = "t3.nano"
  # min_size            = 2
  # max_size            = 5
  # desired_capacity    = 3
}

provider "aws" {
  # Change this to your desired region
  region = "us-east-1"
}

resource "aws_vpc" "main" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.16.0.0/24"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "172.16.1.0/24"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "instance" {
  vpc_id = aws_vpc.main.id

  // allow SSH from other machines on the subnet
  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = [
      aws_subnet.private.cidr_block,
      aws_subnet.public.cidr_block
    ]
  }

  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "instance_connect" {
  name        = "allow egress to all vpc subnets"
  description = "Security group to allow SSH to vpc subnets. Created for use with EC2 Instance Connect Endpoint."
  vpc_id      = aws_vpc.main.id

  egress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = [
      aws_subnet.private.cidr_block,
      aws_subnet.public.cidr_block
    ]
  }
}

resource "aws_ec2_instance_connect_endpoint" "instance_connect_endpoint" {
  subnet_id          = aws_subnet.public.id
  preserve_client_ip = false
  security_group_ids = [
    aws_security_group.instance_connect.id
  ]

  tags = {
    Name = "firezone-gateway-instance-connect-endpoint"
  }
}

output "nat_public_ip" {
  description = "The public IP of the NAT gateway"
  value       = aws_eip.nat.public_ip
}
