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

variable "compute_instance_availability_zones" {
  type        = list(string)
  default     = []
  description = "List of zones in the region defined in `compute_region` where replicas should be deployed. Empty list means that all available zones will be used."
}

variable "compute_instance_replicas" {
  type = string
}

variable "compute_instance_type" {
  type = string
}

variable "compute_provision_public_ipv4_address" {
  type        = bool
  default     = true
  description = "Whether to provision public IPv4 address for the instances."
}

variable "compute_provision_public_ipv6_address" {
  type        = bool
  default     = true
  description = "Whether to provision public IPv4 address for the instances."
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
## Regional Instance Group
################################################################################

variable "name" {
  type     = string
  nullable = true
  default  = "gateway"

  description = "Name of the application."
}

variable "labels" {
  type     = map(string)
  nullable = false
  default  = {}

  description = "Labels to add to all created by this module resources."
}

################################################################################
## Firezone Gateway
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

variable "artifact_url" {
  type        = string
  default     = "https://storage.googleapis.com/firezone-prod-artifacts/firezone-gateway"
  description = "URL from which Firezone install script will download the gateway binary"
}

variable "vsn" {
  type        = string
  default     = "latest"
  description = "Version of the Firezone gateway that is downloaded from `artifact_url`."
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

  default = {
    name     = "health"
    protocol = "TCP"
    port     = 8080

    initial_delay_sec = 100

    check_interval_sec  = 15
    timeout_sec         = 10
    healthy_threshold   = 1
    unhealthy_threshold = 3

    http_health_check = {
      request_path = "/healthz"
    }
  }

  description = "Health check which will be used for auto healing policy."
}
