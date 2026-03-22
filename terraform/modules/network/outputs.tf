output "vpc_self_link" {
  value = google_compute_network.aegis_vpc.self_link
}

output "subnet_self_link" {
  value = google_compute_subnetwork.aegis_subnet.self_link
}

output "subnet_name" {
  value = google_compute_subnetwork.aegis_subnet.name
}
