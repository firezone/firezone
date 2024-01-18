output "id" {
  description = "The ID of the instance"
  value = try(
    aws_instance.this.id,
    null,
  )
}

output "arn" {
  description = "The ARN of the instance"
  value = try(
    aws_instance.this.arn,
    null,
  )
}

output "instance_state" {
  description = "The state of the instance"
  value = try(
    aws_instance.this.instance_state,
    null,
  )
}

output "primary_network_interface_id" {
  description = "The ID of the instance's primary network interface"
  value = try(
    aws_instance.this.primary_network_interface_id,
    null,
  )
}

output "public_ip" {
  description = "The public IP address assigned to the instance, if applicable. NOTE: If you are using an aws_eip with your instance, you should refer to the EIP's address directly and not use `public_ip` as this field will change after the EIP is attached"
  value = try(
    aws_instance.this.public_ip,
    null,
  )
}

output "private_ip" {
  description = "The private IP address assigned to the instance"
  value = try(
    aws_instance.this.private_ip,
    null,
  )
}

output "ipv6_addresses" {
  description = "The IPv6 address assigned to the instance, if applicable"
  value = try(
    aws_instance.this.ipv6_addresses,
    [],
  )
}
