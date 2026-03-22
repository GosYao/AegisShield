output "agent_sa_email" {
  value = google_service_account.agent_sa.email
}

output "supervisor_sa_email" {
  value = google_service_account.supervisor_sa.email
}

output "gcs_bucket_name" {
  value = google_storage_bucket.financial_data.name
}
