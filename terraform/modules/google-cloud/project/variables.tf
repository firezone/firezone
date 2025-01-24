variable "organization_id" {
  description = "ID of a Google Cloud Organization"
}

variable "billing_account_id" {
  description = "ID of a Google Cloud Billing Account which will be used to pay for resources"
}

variable "name" {
  description = "Name of a Google Cloud Project"
}

variable "id" {
  description = "ID of a Google Cloud Project. Can be omitted and will be generated automatically"
  default     = ""
}

variable "auto_create_network" {
  description = "Whether to create a default network in the project"
  default     = "true"
}
