variable "aws_gateway_token" {
  type        = string
  description = "Firezone Gateway token for AWS gateway"
  default     = null
  sensitive   = true
}

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

variable "slack_alerts_channel" {
  type        = string
  description = "Slack channel which will receive monitoring alerts"
  default     = "#feed-staging"
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

variable "firezone_client_token" {
  type      = string
  sensitive = true
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

variable "billing_budget_amount" {
  type        = number
  description = "Monthly budget in USD for billing alerts"
}
