variable "project_id" {
  type        = string
  description = "ID of a Google Cloud Project"
}

################################################################################
## Compute
################################################################################

variable "instances" {
  type = map(object({
    cidr_range = string
    type       = string
    replicas   = number
    zones      = list(string)
  }))

  description = "List deployment locations for the application."
}

################################################################################
## Container Registry
################################################################################

variable "container_registry" {
  type        = string
  nullable    = false
  description = "Container registry URL to pull the image from."
}

################################################################################
## Container Image
################################################################################

variable "image_repo" {
  type     = string
  nullable = false

  description = "Repo of a container image used to deploy the application."
}

variable "image" {
  type     = string
  nullable = false

  description = "Container image used to deploy the application."
}

variable "image_tag" {
  type     = string
  nullable = false

  description = "Container image used to deploy the application."
}

################################################################################
## Observability
################################################################################

variable "observability_log_level" {
  type     = string
  nullable = false
  default  = "info"

  description = "Sets RUST_LOG environment variable which applications should use to configure Rust Logger. Default: 'info'."
}

################################################################################
## Application
################################################################################

variable "application_name" {
  type     = string
  nullable = true
  default  = null

  description = "Name of the application. Defaults to value of `var.image_name` with `_` replaced to `-`."
}

variable "application_version" {
  type     = string
  nullable = true
  default  = null

  description = "Version of the application. Defaults to value of `var.image_tag`."
}

variable "application_labels" {
  type     = map(string)
  nullable = false
  default  = {}

  description = "Labels to add to all created by this module resources."
}

variable "health_check" {
  type = object({
    name     = string
    protocol = string
    port     = number

    initial_delay_sec   = number
    check_interval_sec  = optional(number)
    timeout_sec         = optional(number)
    healthy_threshold   = optional(number)
    unhealthy_threshold = optional(number)

    http_health_check = optional(object({
      host         = optional(string)
      request_path = optional(string)
      port         = optional(string)
      response     = optional(string)
    }))
  })

  nullable = false

  description = "Health check which will be used for auto healing policy."
}

variable "application_environment_variables" {
  type = list(object({
    name  = string
    value = string
  }))

  nullable = false
  default  = []

  description = "List of environment variables to set for all application containers."
}

################################################################################
## Firezone
################################################################################

variable "token" {
  type        = string
  description = "Portal token to use for authentication."
  sensitive   = true
}

variable "api_url" {
  type        = string
  default     = "wss://api.firezone.dev"
  description = "URL of the control plane endpoint."
}
