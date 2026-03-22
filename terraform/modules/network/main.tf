resource "google_compute_network" "aegis_vpc" {
  name                    = "aegis-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "aegis_subnet" {
  name                     = "aegis-subnet"
  region                   = var.region
  network                  = google_compute_network.aegis_vpc.self_link
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true
  project                  = var.project_id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

resource "google_compute_router" "aegis_router" {
  name    = "aegis-router"
  region  = var.region
  network = google_compute_network.aegis_vpc.self_link
  project = var.project_id
}

resource "google_compute_router_nat" "aegis_nat" {
  name                               = "aegis-nat"
  router                             = google_compute_router.aegis_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  project                            = var.project_id
}
