variable "image_tag" {
  type        = string
  description = "Image tag for all services. Notice: we assume all services are deployed with the same version"
}

variable "metabase_image_tag" {
  type    = string
  default = "v0.47.6"
}

variable "relay_token" {
  type      = string
  default   = null
  sensitive = true
}

variable "gateway_token" {
  type      = string
  default   = null
  sensitive = true
}

variable "slack_alerts_channel" {
  type        = string
  description = "Slack channel which will receive monitoring alerts"
  default     = "#feed-production"
}

variable "slack_alerts_auth_token" {
  type        = string
  description = "Slack auth token for the infra alerts channel"
  sensitive   = true
}

variable "postmark_server_api_token" {
  type      = string
  sensitive = true
}

variable "mailgun_server_api_token" {
  type      = string
  sensitive = true
}

variable "pagerduty_auth_token" {
  type      = string
  sensitive = true
}

variable "stripe_secret_key" {
  type      = string
  sensitive = true
}

variable "stripe_webhook_signing_secret" {
  type      = string
  sensitive = true
}

variable "stripe_default_price_id" {
  type = string
}

variable "workos_api_key" {
  type      = string
  sensitive = true
}

variable "workos_client_id" {
  type      = string
  sensitive = true
}

variable "workos_base_url" {
  type = string
}

# Version overrides
#
# This section should be used to bind a specific version of the Firezone component
# (eg. during rollback) to ensure it's not replaced by a new one until a manual action
#
# To update them go to Terraform Cloud and change/delete the following variables,
# if they are unset `var.image_tag` will be used.

variable "relay_image_tag" {
  type    = string
  default = null
}

variable "gateway_image_tag" {
  type    = string
  default = null
}

variable "portal_image_tag" {
  type    = string
  default = null
}
