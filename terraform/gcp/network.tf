resource "google_compute_network" "vm_network" {
  name                    = "vm-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vm_subnetwork" {
  name          = "vm-subnetwork"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vm_network.id
}
