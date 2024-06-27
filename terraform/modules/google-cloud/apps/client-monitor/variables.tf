variable "project_id" {
  type        = string
  description = "ID of a Google Cloud Project"
}

################################################################################
## Compute
################################################################################

variable "compute_network" {
  type = string
}

variable "compute_subnetwork" {
  type = string
}

variable "compute_region" {
  type = string
}

variable "compute_instance_availability_zone" {
  type        = string
  description = "List of zones in the region defined in `compute_region` where replicas should be deployed."
}

variable "compute_instance_type" {
  type = string
}

################################################################################
## Container Registry
################################################################################

variable "container_registry" {
  type        = string
  nullable    = false
  description = "Container registry URL to pull the image from."
}

###############################################################################
# Container Image
###############################################################################

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

  description = "List of environment variables to set for the application."
}

################################################################################
## Firezone Client
################################################################################

variable "firezone_api_url" {
  type     = string
  nullable = false
  default  = "wss://api.firez.one"

  description = "URL the firezone client will connect to"
}

variable "firezone_client_id" {
  type     = string
  nullable = false
  default  = ""

  description = ""
}

variable "firezone_token" {
  type    = string
  default = ""

  description = "Firezone token to allow client to connect to portal"
  sensitive   = true
}

variable "firezone_client_log_level" {
  type    = string
  default = "debug"

  description = "Firezone client Rust log level"
}
