variable "version" {
  type        = string
  description = "Image tag for all services. Notice: we assume all services are deployed with the same version"
}

variable "relay_portal_token" {
  type    = string
  default = null
}

variable "slack_alerts_channel" {
  type        = string
  description = "Slack channel which will receive monitoring alerts"
  default     = "#alerts-infra"
}

variable "slack_alerts_auth_token" {
  type        = string
  description = "Slack auth token for the infra alerts channel"
}

variable "postmark_server_api_token" {
  type = string
}
