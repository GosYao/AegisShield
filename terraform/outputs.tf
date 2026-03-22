output "cluster_endpoint" {
  description = "GKE cluster API server endpoint"
  value       = module.gke.cluster_endpoint
  sensitive   = true
}

output "agent_gcp_sa_email" {
  description = "GCP Service Account email for the agent (used in KSA annotation)"
  value       = module.iam.agent_sa_email
}

output "supervisor_gcp_sa_email" {
  description = "GCP Service Account email for the supervisor"
  value       = module.iam.supervisor_sa_email
}

output "gcs_bucket_name" {
  description = "GCS bucket name containing financial data"
  value       = module.iam.gcs_bucket_name
}

output "get_credentials_command" {
  description = "Command to configure kubectl"
  value       = "gcloud container clusters get-credentials ${var.cluster_name} --zone ${var.zone} --project ${var.project_id}"
}
