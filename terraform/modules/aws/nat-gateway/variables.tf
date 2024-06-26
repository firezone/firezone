variable "base_ami" {
  description = "The base AMI for the instances"
  type        = string
}

variable "instance_type" {
  description = "The instance type"
  type        = string
  default     = "t3.nano"
}

variable "desired_capacity" {
  description = "The desired number of instances"
  type        = number
  default     = 3
}

variable "min_size" {
  description = "The minimum number of instances"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "The maximum number of instances"
  type        = number
  default     = 5
}

variable "firezone_token" {
  description = "The Firezone token"
  type        = string
  nullable    = false
  sensitive   = true
}

variable "firezone_version" {
  description = "The Gateway version to deploy"
  type        = string
  default     = "latest"
}

variable "firezone_api_url" {
  description = "The Firezone API URL"
  type        = string
  default     = "wss://api.firezone.dev"
}

variable "vpc" {
  description = "The VPC id to use"
  type        = string
}

variable "private_subnet" {
  description = "The private subnet id"
  type        = string
}

variable "public_subnet" {
  description = "The public subnet id"
  type        = string
}

variable "instance_security_groups" {
  description = "The security group ids to attach to the instances"
  type        = list(string)
}

variable "extra_tags" {
  description = "Extra tags for the Auto Scaling group"

  type = map(object({
    key                 = string
    value               = string
    propagate_at_launch = bool
  }))

  default = {}
}
