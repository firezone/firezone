variable "image_tag" {
  type        = string
  description = "Image tag for all services. Notice: we assume all services are deployed with the same version"
}

variable "metabase_image_tag" {
  type    = string
  default = "v0.47.6"
}

variable "relay_token" {
  type    = string
  default = null
}

variable "gateway_token" {
  type    = string
  default = null
}

variable "slack_alerts_channel" {
  type        = string
  description = "Slack channel which will receive monitoring alerts"
  default     = "#feed-production"
}

variable "slack_alerts_auth_token" {
  type        = string
  description = "Slack auth token for the infra alerts channel"
}

variable "postmark_server_api_token" {
  type = string
}

variable "mailgun_server_api_token" {
  type = string
}

variable "pagerduty_auth_token" {
  type = string
}
