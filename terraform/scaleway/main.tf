resource "scaleway_instance_security_group" "sg" {
  name        = "starlake-sg"
  description = "Security group for Starlake Data Stack"
  inbound_default_policy = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action = "accept"
    port   = 22
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }

  inbound_rule {
    action = "accept"
    port   = 80
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }

  inbound_rule {
    action = "accept"
    port   = 443
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }

  inbound_rule {
    action = "accept"
    port   = 10900
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }
}

resource "scaleway_instance_ip" "public_ip" {
  count = var.reserve_ip ? 1 : 0
}

resource "scaleway_instance_server" "web" {
  type        = var.instance_type
  image       = var.image
  name        = "starlake-instance"
  tags        = ["starlake-data-stack", "http-server", "https-server"]
  ip_id       = var.reserve_ip ? scaleway_instance_ip.public_ip[0].id : null

  security_group_id = scaleway_instance_security_group.sg.id

  user_data = {
    cloud-init = templatefile("${path.module}/startup.sh", {
        repo_url     = var.repo_url
        repo_branch  = var.repo_branch
        repo_tag     = var.repo_tag
        enable_https = var.enable_https
        domain_name  = var.domain_name
        email        = var.email
    })
  }
}
