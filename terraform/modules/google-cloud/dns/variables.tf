variable "project_id" {
  description = "The ID of the project in which the resource belongs."
}

variable "tld" {
  description = "The top level domain to use for the cluster. Should end with a dot, eg: 'app.firez.one.'"
  type        = string
}

variable "dnssec_enabled" {
  description = "Whether or not to enable DNSSEC"
  type        = bool
}
