variable "project_id" {
  type        = string
  description = "ID of a Google Cloud Project"
}

################################################################################
## Compute
################################################################################

variable "compute_network" {
  type = string
}

variable "compute_subnetwork" {
  type = string
}

variable "compute_region" {
  type = string
}

variable "compute_instance_availability_zone" {
  type        = string
  description = "List of zones in the region defined in `compute_region` where replicas should be deployed."
}

variable "compute_instance_type" {
  type        = string
  description = "Machine type to use for the instances."
}

################################################################################
## Boot Image
################################################################################

variable "boot_image_family" {
  type        = string
  description = "Family of the boot image to use for the instances."
  default     = "ubuntu-2204-lts"
}

variable "boot_image_project" {
  type        = string
  description = "Project of the boot image to use for the instances."
  default     = "ubuntu-os-cloud"
}

################################################################################
## Virtual Machine
################################################################################

variable "vm_name" {
  type     = string
  nullable = true
  default  = null

  description = "Name of the VM to create."
}

variable "vm_labels" {
  type     = map(string)
  nullable = false
  default  = {}

  description = "Labels to add to all created by this module resources."
}

variable "vm_network_tag" {
  type     = string
  nullable = false

  description = "Network tags to add to VM created by this module."
}

################################################################################
## Cloud-init Configuration
################################################################################

variable "cloud_init" {
  type        = string
  description = "Cloud-init configuration to use for the VM."
}
