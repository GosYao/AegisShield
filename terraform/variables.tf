variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for zonal resources"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "aegis-cluster"
}

variable "gcs_bucket_name" {
  description = "GCS bucket holding financial data"
  type        = string
  default     = "aegis-financial-data"
}

variable "agent_gcp_sa_name" {
  description = "GCP SA name for the agent workload"
  type        = string
  default     = "aegis-agent-sa"
}

variable "agent_k8s_namespace" {
  description = "Kubernetes namespace for agent workload"
  type        = string
  default     = "aegis-mesh"
}

variable "agent_ksa_name" {
  description = "Kubernetes Service Account name for agent"
  type        = string
  default     = "agent-ksa"
}
