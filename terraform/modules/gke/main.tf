resource "google_container_cluster" "aegis" {
  provider = google-beta
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id

  # Remove default node pool; manage pools separately
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network_self_link
  subnetwork = var.subnet_self_link

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Cilium / Dataplane V2 — required for CiliumNetworkPolicy enforcement
  datapath_provider = "ADVANCED_DATAPATH"

  # Workload Identity — allows KSAs to impersonate GCP SAs
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Fleet registration — required for managed Cloud Service Mesh
  fleet {
    project = var.project_id
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  # Private nodes; public endpoint for demo convenience
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "all-for-demo"
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
}

# System node pool — CPU workloads (ArgoCD, agent, supervisor, FortiAIGate)
resource "google_container_node_pool" "system" {
  name       = "system-pool"
  cluster    = google_container_cluster.aegis.name
  location   = var.zone
  project    = var.project_id
  node_count = 2

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 100
    image_type   = "COS_CONTAINERD"

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      pool = "system"
    }
  }
}

# GPU node pool — G2/L4 for vLLM inference (Mistral-7B, phi-3-mini)
resource "google_container_node_pool" "gpu" {
  name       = "gpu-pool"
  cluster    = google_container_cluster.aegis.name
  location   = var.zone
  project    = var.project_id
  node_count = 2

  node_config {
    machine_type = "g2-standard-4"
    disk_size_gb = 100
    image_type   = "COS_CONTAINERD"

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      pool        = "gpu"
      accelerator = "nvidia-l4"
    }

    # Taint prevents non-GPU workloads from landing on GPU nodes
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }
  }
}
