variable "resource_group_location" {
  description = "The location for the resource group"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "source_image_reference" {
  description = "The source image reference for the instances"
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })

  default = {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

variable "instance_type" {
  description = "The instance type"
  type        = string
  default     = "Standard_B1ls"
}

variable "desired_capacity" {
  description = "The desired number of instances"
  type        = number
  default     = 3
}

variable "admin_username" {
  description = "The admin username"
  type        = string
  default     = "firezone"
}

variable "admin_ssh_key" {
  description = "The admin SSH public key"
  type        = string
}

variable "firezone_token" {
  description = "The Firezone token"
  type        = string
  sensitive   = true
}

variable "firezone_version" {
  description = "The Gateway version to deploy"
  type        = string
  default     = "latest"
}

variable "firezone_name" {
  description = "Name for the Gateways used in the admin portal"
  type        = string
  default     = "$(hostname)"
}

variable "firezone_api_url" {
  description = "The Firezone API URL"
  type        = string
  default     = "wss://api.firezone.dev"
}

variable "private_subnet" {
  description = "The private subnet ID"
  type        = string
}

variable "network_security_group_id" {
  description = "The network security group id to attach to the instances"
  type        = string
}

variable "extra_tags" {
  description = "Extra tags to attach to the instances"
  type        = map(string)
  default     = { "Name" = "firezone-gateway-instance" }
}

variable "platform_fault_domain_count" {
  description = "The number of fault domains"
  type        = number
  default     = 3
}

variable "nat_gateway_id" {
  description = "The NAT gateway ID"
  type        = string
}
