variable "project_id" {
  type        = string
  description = "ID of a Google Cloud Project"
}

################################################################################
## Compute
################################################################################

variable "instances" {
  type = map(object({
    subnet   = string
    type     = string
    replicas = number
    zones    = list(string)
  }))

  description = "List deployment locations for the application."
}

variable "network" {
  type        = string
  description = "ID of a Google Cloud Network"
}

# Ensure instances are recreated when this is changed.
variable "naming_suffix" {
  type        = string
  description = "Suffix to append to the name of resources."
}

# Maximum NIC Rx/Tx queue count. The default is 1. Adjust this based on number of vCPUs.
# NOTE: Minimum of 2 is required for XDP programs to load onto the NIC.
# This is because the `gve` driver expects the number of active queues to be
# less than or equal to half the maximum number of queues.
# The active queue count will need to be set at boot in order to be half this, because
# gve driver defaults to setting the active queue count to the maximum.
# NOTE 2: The maximum number here should max the number of vCPUs.
variable "queue_count" {
  type        = number
  default     = 2
  description = "Number of max RX / TX queues to assign to the NIC."

  validation {
    condition     = var.queue_count >= 2
    error_message = "queue_count must be greater than or equal to 2."
  }

  validation {
    condition     = var.queue_count % 2 == 0
    error_message = "queue_count must be an even number."
  }

  validation {
    condition     = var.queue_count <= 16
    error_message = "queue_count must be less than or equal to 16."
  }
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
