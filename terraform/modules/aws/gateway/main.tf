locals {
  application_name    = var.application_name != null ? var.application_name : var.image
  application_version = var.application_version != null ? var.application_version : var.image_tag

  environment_variables = concat([
    {
      name  = "RUST_LOG"
      value = var.observability_log_level
    },
    {
      name  = "RUST_BACKTRACE"
      value = "full"
    },
    {
      name  = "FIREZONE_TOKEN"
      value = var.token
    },
    {
      name  = "FIREZONE_API_URL"
      value = var.api_url
    },
    {
      name  = "FIREZONE_ENABLE_MASQUERADE"
      value = "1"
    }
  ], var.application_environment_variables)
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

  #user_data = file("${path.module}/scripts/setup.sh")
  user_data = templatefile("${path.module}/templates/cloud-init.yaml", {
    container_name        = local.application_name != null ? local.application_name : var.image
    container_image       = "${var.container_registry}/${var.image_repo}/${var.image}:${var.image_tag}"
    container_environment = local.environment_variables
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  tags = merge({ "Name" = var.name }, var.instance_tags, var.tags)
}
