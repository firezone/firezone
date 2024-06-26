module "ec2_with_nat" {
  # Required inputs
  source           = "github.com/firezone/firezone/terraform/modules/aws/nat-gateway"
  firezone_token   = "YOUR_FIREZONE_TOKEN"
  firezone_api_url = "wss://app.firezone.dev"
  base_ami         = "ami-0a640b520696dc6a8" # Ubuntu 22.04
  region           = "us-east-1"

  # Optional inputs
  # firezone_version    = "latest"
  # instance_type       = "t3.nano"
  # min_size            = 2
  # max_size            = 5
  # desired_capacity    = 3
  # vpc_cidr            = "10.0.0.0/16"
  # public_subnet_cidr  = "10.0.1.0/24"
  # private_subnet_cidr = "10.0.2.0/24"
}
