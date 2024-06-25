output "nat_public_ip" {
  description = "The public IP of the NAT gateway"
  value       = aws_eip.nat.public_ip
}
