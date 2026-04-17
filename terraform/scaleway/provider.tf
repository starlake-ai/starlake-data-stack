terraform {
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      version = "~> 2.39.0"
    }
  }
}

provider "scaleway" {
  zone   = var.zone
  region = var.region
  # Credentials usually loaded from env vars or config file
}
