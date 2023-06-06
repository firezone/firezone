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
