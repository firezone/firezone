module "ec2_with_nat" {
  source              = "../../../modules/aws/nat-gateway"
  firezone_token      = "YOUR_FIREZONE_TOKEN"
  firezone_version    = "latest"
  base_ami            = "ami-0a640b520696dc6a8" # Ubuntu 22.04
  instance_type       = "t2.micro"
  instance_count      = 3
  region              = "us-east-1"
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24"
  private_subnet_cidr = "10.0.2.0/24"
}
