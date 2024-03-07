################################################################################
## Account
################################################################################

variable "project_id" {
  type        = string
  description = "Google Cloud Project ID"
}

################################################################################
## Compute
################################################################################

variable "region" {
  type        = string
  description = "Region to deploy the Gateway(s) in."
}

variable "zone" {
  type        = string
  description = "Availability to deploy the Gateway(s) in."
}

variable "replicas" {
  type        = number
  description = "Number of Gateway replicas to deploy in the availability zone."
  default     = 3
}

variable "machine_type" {
  type    = string
  default = "n1-standard-1"
}

################################################################################
## Observability
################################################################################

variable "log_level" {
  type     = string
  nullable = false
  default  = "info"

  description = "Sets RUST_LOG environment variable to configure the Gateway's log level. Default: 'info'."
}

################################################################################
## Firezone
################################################################################

variable "token" {
  type        = string
  description = "Gateway token to use for authentication."
}
