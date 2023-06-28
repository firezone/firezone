variable "project_id" {
  type        = string
  description = "ID of a Google Cloud Project"
}

################################################################################
## Compute
################################################################################

variable "compute_instance_type" {
  type        = string
  description = "Type of the instance."
  default     = "n1-standard-1"
}

variable "instances" {
  type = map(string(map(string(object({
    type     = string
    replicas = number
  })))))

  description = "List deployment locations for the application."
}

################################################################################
## VPC
################################################################################

variable "vpc_network" {
  description = "ID of a VPC which will be used to deploy the application."
  type        = string
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

  validation {
    condition = (
      contains(
        ["trace", "debug", "info", "warn", "error"],
        var.observability_log_level
      )
    )
    error_message = "Invalid log level."
  }

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

variable "application_ports" {
  type = list(object({
    name     = string
    protocol = string
    port     = number

    health_check = object({
      initial_delay_sec   = number
      check_interval_sec  = optional(number)
      timeout_sec         = optional(number)
      healthy_threshold   = optional(number)
      unhealthy_threshold = optional(number)

      tcp_health_check = optional(object({}))

      http_health_check = optional(object({
        host         = optional(string)
        request_path = optional(string)
        port         = optional(string)
        response     = optional(string)
      }))

      https_health_check = optional(object({
        host         = optional(string)
        request_path = optional(string)
        port         = optional(string)
        response     = optional(string)
      }))
    })
  }))

  nullable = false
  default  = []

  description = "List of ports to expose for the application. One of ports MUST be named 'http' for auth healing policy to work."
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
