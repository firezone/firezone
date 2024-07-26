variable "postgres_password" {
  type        = string
  description = "The password for the PostgreSQL server"
  sensitive   = true
}

variable "token" {
  type        = string
  description = "The token for the Firezone Gateways"
  sensitive   = true
}

# variable "metabase_password" {
#   type        = string
#   description = "The password for the Metabase application"
#   sensitive   = true
# }
