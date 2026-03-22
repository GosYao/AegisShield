variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "agent_gcp_sa_name" {
  description = "GCP SA name for the agent workload"
  type        = string
}

variable "gcs_bucket_name" {
  description = "GCS bucket holding financial data"
  type        = string
}

variable "agent_k8s_namespace" {
  description = "Kubernetes namespace where the agent KSA lives"
  type        = string
}

variable "agent_ksa_name" {
  description = "Kubernetes Service Account name for the agent"
  type        = string
}
