variable "project_id" {
  description = "The ID of the project in which the resource belongs."
}

variable "compute_region" {
  description = "The region the instance will sit in."
}

variable "compute_availability_zone" {
  description = "The preferred compute engine zone. See https://cloud.google.com/compute/docs/regions-zones?hl=en"
}

variable "compute_instance_memory_size" {
  description = "Instance memory size. See https://cloud.google.com/compute/docs/instances/creating-instance-with-custom-machine-type#create"
}

variable "compute_instance_cpu_count" {
  description = "Count of CPUs. See https://cloud.google.com/compute/docs/instances/creating-instance-with-custom-machine-type#create"
}

variable "network" {
  description = "Full network identifier which is used to create private VPC connection with Cloud SQL instance"
}

variable "database_name" {
  description = "Name of the Cloud SQL database"
}

variable "database_version" {
  description = "Version of the Cloud SQL database"
  default     = "POSTGRES_17"
}

variable "database_highly_available" {
  description = "Creates a failover copy for the master intancy and makes it availability regional."
  default     = false
}

variable "database_backups_enabled" {
  description = "Should backups be enabled on this database?"
  default     = false
}

variable "database_read_replica_locations" {
  description = "List of read-only replicas to create."
  type = list(object({
    region       = string
    ipv4_enabled = bool
    network      = string
  }))
  default = []
}

variable "database_flags" {
  description = "List of PostgreSQL database flags. Can be used to install Postgres extensions."
  type        = map(string)
  default     = {}
}
