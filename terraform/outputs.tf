# ── Outputs: values exported after terraform apply ────────────────────────────
# Outputs make key infrastructure values accessible to other Terraform modules
# and to scripts. They also appear in the terminal after every `terraform apply`.

output "cluster_name" {
  description = "GKE cluster name — used in gcloud and kubectl commands"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "GKE cluster API server endpoint"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true   # marked sensitive: won't print in plain text in CI logs
}

output "cluster_location" {
  description = "GKE cluster region"
  value       = google_container_cluster.primary.location
}

output "get_credentials_command" {
  description = "Run this command to configure kubectl after terraform apply"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${google_container_cluster.primary.location} --project ${var.project_id}"
}
