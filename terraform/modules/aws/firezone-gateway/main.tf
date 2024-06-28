resource "aws_launch_configuration" "lc" {
  name                        = "firezone-gateway-lc"
  image_id                    = var.base_ami
  instance_type               = var.instance_type
  security_groups             = var.instance_security_groups
  associate_public_ip_address = false

  lifecycle {
    create_before_destroy = true
  }

  user_data = <<-EOF
  #!/bin/bash
  set -e

  sudo apt-get update
  sudo apt-get install -y curl uuid-runtime

  FIREZONE_TOKEN="${var.firezone_token}" \
  FIREZONE_VERSION="${var.firezone_version}" \
  FIREZONE_NAME="${var.firezone_name}" \
  FIREZONE_ID="$(uuidgen)" \
  FIREZONE_API_URL="${var.firezone_api_url}" \
  bash <(curl -fsSL https://raw.githubusercontent.com/firezone/firezone/main/scripts/gateway-systemd-install.sh)

  EOF
}

resource "aws_autoscaling_group" "asg" {
  desired_capacity     = var.desired_capacity
  max_size             = var.max_size
  min_size             = var.min_size
  vpc_zone_identifier  = [var.private_subnet]
  launch_configuration = aws_launch_configuration.lc.id

  tag {
    key                 = "Name"
    value               = "firezone-gateway-instance"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.extra_tags
    content {
      key                 = tag.value.key
      propagate_at_launch = tag.value.propagate_at_launch
      value               = tag.value.value
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
