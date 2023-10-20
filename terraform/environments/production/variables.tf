variable "api_image_tag" {
  type        = string
  description = "Image tag for the api service"
}

variable "web_image_tag" {
  type        = string
  description = "Image tag for the web service"
}

variable "relay_image_tag" {
  type        = string
  description = "Image tag for the relay service"
}

variable "relay_portal_token" {
  type    = string
  default = null
}

variable "slack_alerts_channel" {
  type        = string
  description = "Slack channel which will receive monitoring alerts"
  default     = "#feed-infra"
}

variable "slack_alerts_auth_token" {
  type        = string
  description = "Slack auth token for the infra alerts channel"
}

variable "postmark_server_api_token" {
  type = string
}
