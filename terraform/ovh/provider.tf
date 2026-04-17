terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 0.43.0"
    }
  }
}

provider "openstack" {
  auth_url    = var.auth_url
  region      = var.region
  # Credentials usually loaded from env vars or clouds.yaml
}

provider "ovh" {
  endpoint = "ovh-eu"
}
