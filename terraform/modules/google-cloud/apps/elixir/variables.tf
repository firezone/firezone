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

variable "compute_instance_region" {
  type        = string
  description = "Region which would be used to create compute resources."
}

variable "compute_instance_availability_zones" {
  type        = list(string)
  description = "List of availability zone for the VMs. It must be in the same region as `var.compute_instance_region`."
}

variable "compute_boot_disk_type" {
  type        = string
  default     = "pd-ssd"
  description = "Type of the boot disk."
}

variable "compute_swap_size_gb" {
  type        = number
  default     = 0
  description = "Size of the swap disk in GB."
}

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
## VPC
################################################################################

variable "vpc_network" {
  description = "ID of a VPC which will be used to deploy the application."
  type        = string
}

variable "vpc_subnetwork" {
  description = "ID of a VPC subnet which will be used to deploy the application."
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
## Scaling
################################################################################

variable "scaling_horizontal_replicas" {
  type     = number
  nullable = false
  default  = 1

  validation {
    condition     = var.scaling_horizontal_replicas > 0
    error_message = "Number of replicas should be greater or equal to 0."
  }

  description = "Number of replicas in an instance group."
}

variable "reservation_size" {
  type     = number
  nullable = false
  default  = 1

  validation {
    condition     = var.reservation_size >= var.scaling_horizontal_replicas
    error_message = "Reservation size should be greater or equal to the number of scaling_horizontal_replicas."
  }

  description = "Number of reservations to create."
}

variable "scaling_max_horizontal_replicas" {
  type     = number
  nullable = true
  default  = null

  description = "Maximum number of replacias an instance group can be auto-scaled to. `null` disables auto-scaling."
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
        ["emergency", "alert", "critical", "error", "warning", "notice", "info", "debug"],
        var.observability_log_level
      )
    )
    error_message = "Only Elixir Logger log levels are accepted."
  }

  description = "Sets LOG_LEVEL environment variable which applications should use to configure Elixir Logger. Default: 'info'."
}


################################################################################
## Erlang
################################################################################

variable "erlang_release_name" {
  type     = string
  nullable = true
  default  = null

  description = <<EOT
  Name of an Erlang/Elixir release which should correspond to shell executable name which is used to run the container.

  By default an `var.image_tag` with `-` replaced to `_` would be used.
EOT
}

variable "erlang_cluster_cookie" {
  type     = string
  nullable = false

  description = "Value of the Erlang cluster cookie."
}


variable "erlang_cluster_disterl_port" {
  type     = number
  nullable = false
  default  = 10000

  description = <<EOT
  Sets the `LISTEN_DIST_MIN` and `LISTEN_DIST_MAX` environment variables that can be used by setting
  `ELIXIR_ERL_OPTIONS="-kernel inet_dist_listen_min $\{LISTEN_DIST_MIN} inet_dist_listen_max $\{LISTEN_DIST_MAX}"`
  option in `env.sh.eex` for Elixir release.

  This helps when you want to forward the port from localhost to the cluster and connect to a remote Elixir node debugging
  it in production.

  Default: 10000.
EOT
}

variable "erlang_cluster_node_name" {
  type     = string
  nullable = true
  default  = null

  description = <<EOT
  Name of the node in the Erlang cluster. Defaults to `replace(var.image_name, "_", "-")`.
EOT
}

################################################################################
## DNS
################################################################################

variable "dns_managed_zone_name" {
  type     = string
  nullable = false

  description = "Name of the DNS managed zone."
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

variable "application_token_scopes" {
  type     = list(string)
  nullable = false
  default  = []

  description = "Any extra oAuth2 token scopes granted to the token of default service account."
}

variable "application_dns_tld" {
  type     = string
  nullable = true
  default  = null

  description = "DNS host which will be used to create DNS records for the application and provision SSL-certificates."
}

variable "application_cdn_enabled" {
  type     = bool
  nullable = false
  default  = false

  description = "Enable CDN for all static assets the application."
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

  description = "List of ports to expose for the application. One of ports MUST be named 'http' for auto healing policy to work."
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
