output "project" {
  description = "Project struct which can be used to create resources in this project"
  value       = google_project.project
}

output "name" {
  description = "The project name"
  value       = google_project.project.name
}
