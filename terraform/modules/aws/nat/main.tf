resource "aws_instance" "this" {
  ami                         = var.ami
  instance_type               = var.instance_type
  monitoring                  = var.monitoring
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.vpc_security_group_ids
  associate_public_ip_address = var.associate_public_ip_address
  source_dest_check           = false

  key_name  = var.key_name
  user_data = file("${path.module}/scripts/setup.sh")

  root_block_device {
    volume_type = "gp3"
    volume_size = 15
  }

  tags = merge({ "Name" = var.name }, var.instance_tags, var.tags)
}
