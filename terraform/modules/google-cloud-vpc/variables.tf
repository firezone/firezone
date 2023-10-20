variable "project_id" {
  description = "The ID of the project in which the resource belongs."
}

variable "name" {
  description = "Name of the resource. Provided by the client when the resource is created."
}

variable "nat_region" {
  description = "Region where Cloud NAT will be created"
}
