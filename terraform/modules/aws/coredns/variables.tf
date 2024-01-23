variable "ami" {
  description = "AMI ID for the EC2 instance"
  type        = string
  default     = "ami-0b2a9065573b0a9c9" # Ubuntu 22.04 in us-east-1

  validation {
    condition     = length(var.ami) > 4 && substr(var.ami, 0, 4) == "ami-"
    error_message = "Please provide a valid value for variable AMI."
  }
}

variable "api_url" {
  description = "URL of the control plane endpoint."
  type        = string
  default     = null
}


variable "application_name" {
  description = "Name of the application. Defaults to value of `var.image_name` with `_` replaced to `-`."
  type        = string
  nullable    = true
  default     = null
}

variable "application_version" {
  description = "Version of the application. Defaults to value of `var.image_tag`."
  type        = string
  nullable    = true
  default     = null
}

variable "associate_public_ip_address" {
  description = "Whether to associate a public IP address with an instance in a VPC"
  type        = bool
  default     = true
}

variable "dns_records" {
  description = "List of DNS records to set for CoreDNS."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false
}

variable "instance_type" {
  description = "The type of instance to start"
  type        = string
  default     = "t3.micro"
}

variable "instance_tags" {
  description = "Additional tags for the instance"
  type        = map(string)
  default     = {}
}

variable "ipv6_addresses" {
  description = "Specify one or more IPv6 addresses from the range of the subnet to associate with the primary network interface"
  type        = list(string)
  default     = null
}

variable "key_name" {
  description = "Key name of the Key Pair to use for the instance; which can be managed using the `aws_key_pair` resource"
  type        = string
  default     = null
}

variable "monitoring" {
  description = "If true, the launched EC2 instance will have detailed monitoring enabled"
  type        = bool
  default     = null
}

variable "name" {
  description = "Name to be used on EC2 instance created"
  type        = string
  default     = ""
}

variable "observability_log_level" {
  description = "Sets RUST_LOG environment variable which applications should use to configure Rust Logger. Default: 'info'."
  type        = string
  nullable    = false
  default     = "info"

}

variable "private_ip" {
  description = "Private IP address to associate with the instance in a VPC"
  type        = string
  default     = null
}

variable "root_block_device" {
  description = "Customize details about the root block device of the instance. See Block Devices below for details"
  type        = list(any)
  default     = []
}

variable "subnet_id" {
  description = "The VPC Subnet ID to launch in"
  type        = string
  default     = null
}

variable "tags" {
  description = "A mapping of tags to assign to the resource"
  type        = map(string)
  default     = {}
}

variable "token" {
  description = "Portal token to use for authentication."
  type        = string
  default     = null
}

variable "vpc_security_group_ids" {
  description = "A list of security group IDs to associate with"
  type        = list(string)
  default     = null
}
