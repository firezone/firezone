resource "aws_instance" "this" {
  ami                         = var.ami
  instance_type               = var.instance_type
  monitoring                  = var.monitoring
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.vpc_security_group_ids
  associate_public_ip_address = var.associate_public_ip_address
  private_ip                  = var.private_ip
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/cloud-init.yaml", {
    container_name  = "coredns"
    container_image = "coredns/coredns"
    host_ip         = var.private_ip
    dns_records     = concat([{ name = "coredns", value = var.private_ip }], var.dns_records)
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 15
  }

  tags = merge({ "Name" = var.name }, var.instance_tags, var.tags)
}
