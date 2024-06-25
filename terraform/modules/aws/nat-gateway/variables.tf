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
  default     = 10
}

variable "firezone_token" {
  description = "The Firezone token"
  type        = string
  nullable    = false
}

variable "firezone_version" {
  description = "The Gateway version to deploy"
  type        = string
  default     = "latest"
}

variable "region" {
  description = "The AWS region to deploy to"
  type        = string
}

variable "vpc_cidr" {
  description = "The IPv4 CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "The IPv4 CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "The IPv4 CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}
