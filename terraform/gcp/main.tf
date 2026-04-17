resource "google_compute_address" "static" {
  count = var.reserve_ip ? 1 : 0
  name  = "${var.instance_name}-ip"
}

resource "google_compute_instance" "default" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = var.disk_size
    }
    # Ensure disk is deleted when instance is deleted
    auto_delete = true
  }

  network_interface {
    network    = google_compute_network.vm_network.id
    subnetwork = google_compute_subnetwork.vm_subnetwork.id
    access_config {
      # Use reserved IP if enabled, otherwise ephemeral
      nat_ip = var.reserve_ip ? google_compute_address.static[0].address : null
    }
  }

  tags = ["starlake-data-stack"]

  metadata_startup_script = templatefile("${path.module}/startup.sh", {
    repo_url     = var.repo_url
    repo_branch  = var.repo_branch
    repo_tag     = var.repo_tag
    enable_https = var.enable_https
    domain_name  = var.domain_name
    email        = var.email
  })

  service_account {
    scopes = ["cloud-platform"]
  }

  allow_stopping_for_update = true
}

resource "google_compute_firewall" "default" {
  name    = "allow-starlake-access"
  network = google_compute_network.vm_network.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "22", "10900", "11900-12000"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["starlake-data-stack"]
}
