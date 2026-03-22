provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Enable required GCP APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "mesh.googleapis.com",
    "gkehub.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com",
    "servicemesh.googleapis.com",
    "anthos.googleapis.com",
    "connectgateway.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "network" {
  source     = "./modules/network"
  project_id = var.project_id
  region     = var.region

  depends_on = [google_project_service.apis]
}

module "gke" {
  source            = "./modules/gke"
  project_id        = var.project_id
  zone              = var.zone
  cluster_name      = var.cluster_name
  network_self_link = module.network.vpc_self_link
  subnet_self_link  = module.network.subnet_self_link

  depends_on = [module.network]
}

module "iam" {
  source              = "./modules/iam"
  project_id          = var.project_id
  region              = var.region
  agent_gcp_sa_name   = var.agent_gcp_sa_name
  gcs_bucket_name     = var.gcs_bucket_name
  agent_k8s_namespace = var.agent_k8s_namespace
  agent_ksa_name      = var.agent_ksa_name

  depends_on = [module.gke]
}

# Enable Cloud Service Mesh via GKE Hub
resource "google_gke_hub_feature" "mesh" {
  provider = google-beta
  name     = "servicemesh"
  location = "global"
  project  = var.project_id

  depends_on = [module.gke, google_project_service.apis]
}

resource "google_gke_hub_feature_membership" "mesh_membership" {
  provider   = google-beta
  location   = "global"
  feature    = google_gke_hub_feature.mesh.name
  membership = "${var.zone}/memberships/${var.cluster_name}"
  project    = var.project_id

  mesh {
    management = "MANAGEMENT_AUTOMATIC"
  }

  depends_on = [google_gke_hub_feature.mesh]
}
