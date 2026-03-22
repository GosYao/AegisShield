# GCS bucket containing the financial data the agent is allowed to read
resource "google_storage_bucket" "financial_data" {
  name          = var.gcs_bucket_name
  location      = var.region
  project       = var.project_id
  force_destroy = true

  uniform_bucket_level_access = true
}

# Seed the demo file so the agent has something to retrieve
resource "google_storage_bucket_object" "q3_summary" {
  name   = "q3-summary.json"
  bucket = google_storage_bucket.financial_data.name
  content = jsonencode({
    quarter = "Q3-2025"
    revenue = "142.7M"
    ebitda  = "38.2M"
    note    = "CONFIDENTIAL - Internal Use Only"
  })
}

# GCP Service Account for the Agent pod
resource "google_service_account" "agent_sa" {
  account_id   = var.agent_gcp_sa_name
  display_name = "AegisShield Agent Service Account"
  project      = var.project_id
}

# Grant GCS read-only access on the financial data bucket
resource "google_storage_bucket_iam_member" "agent_gcs_read" {
  bucket = google_storage_bucket.financial_data.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.agent_sa.email}"
}

# Workload Identity binding: Kubernetes SA (agent-ksa) -> GCP SA (aegis-agent-sa)
# The member format must exactly match [namespace/ksa-name] in the cluster
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.agent_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.agent_k8s_namespace}/${var.agent_ksa_name}]"
}

# GCP Service Account for the Supervisor pod
# No GCP IAM permissions needed — pod deletion uses in-cluster RBAC via the mounted KSA token
resource "google_service_account" "supervisor_sa" {
  account_id   = "aegis-supervisor-sa"
  display_name = "AegisShield Supervisor Service Account"
  project      = var.project_id
}
