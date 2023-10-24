variable "project_id" {
  description = "The ID of the project in which the resource belongs."
}

variable "project_name" {
  description = "The name of the project in which the resource belongs."
}

variable "region" {
  description = "The region in which the registry is hosted."
}

variable "writers" {
  description = "The list of IAM members that have write access to the container registry."
  type        = list(string)
}

variable "store_tagged_artifacts_for" {
  description = "Sets the maximum lifetime of artifacts, eg. `300s`. Keep empty to set to `null` to never delete them."
  type        = string
  default     = null
}

variable "store_untagged_artifacts_for" {
  description = "Sets the maximum lifetime of artifacts, eg. `300s`. Keep empty to set to `null` to never delete them."
  type        = string
  default     = null
}
