variable "subscription_id" {
  description = "The Azure billing subscription to use"
  type        = string
}

variable "arm_client_id" {
  description = "The Azure service principal client id"
  type        = string
}

variable "arm_client_secret" {
  description = "The Azure service principal client secret"
  type        = string
}

variable "arm_tenant_id" {
  description = "The Azure service principal tenant id"
  type        = string
}

variable "admin_ssh_pubkey" {
  description = "The SSH public key to use for the admin user"
  type        = string
}

variable "naming_prefix" {
  description = "The prefix to use for all resources"
  type        = string
}
