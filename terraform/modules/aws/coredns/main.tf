locals {
  environment_variables = concat([], var.application_environment_variables)
}

resource "aws_instance" "this" {
  ami                         = var.ami
  instance_type               = var.instance_type
  monitoring                  = var.monitoring
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.vpc_security_group_ids
  associate_public_ip_address = var.associate_public_ip_address
  private_ip                  = var.private_ip
  key_name                    = var.key_name

  user_data = templatefile("${path.module}/templates/cloud-init.yaml", {
    container_name        = "coredns"
    container_image       = "coredns/coredns"
    host_ip               = var.private_ip
    container_environment = local.environment_variables
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 15
  }

  tags = merge({ "Name" = var.name }, var.instance_tags, var.tags)
}
