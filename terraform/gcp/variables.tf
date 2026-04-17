variable "project_id" {
  description = "The ID of the GCP project"
  type        = string
}

variable "region" {
  description = "The region to deploy to"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "The zone to deploy to"
  type        = string
  default     = "europe-west1-b"
}

variable "instance_name" {
  description = "Name of the compute instance"
  type        = string
  default     = "terraform-instance-64gb"
}

variable "machine_type" {
  description = "The machine type to create"
  type        = string
  default     = "e2-highmem-8"
}

variable "disk_size" {
  description = "The size of the boot disk in GB"
  type        = number
  default     = 100
}

variable "repo_url" {
  description = "The URL of the git repository to clone"
  type        = string
  default     = "https://github.com/starlake-ai/starlake-data-stack.git"
}

variable "repo_branch" {
  description = "The branch of the git repository to clone"
  type        = string
  default     = "main"
}

variable "repo_tag" {
  description = "The tag of the git repository to clone (overrides repo_branch if set)"
  type        = string
  default     = ""
}

variable "enable_https" {
  description = "Enable HTTPS using Caddy"
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Domain name for the server (required for valid SSL if enable_https is true)"
  type        = string
  default     = ""
}

variable "email" {
  description = "Email address for Let's Encrypt registration (required if domain_name is set)"
  type        = string
  default     = ""
}

variable "reserve_ip" {
  description = "Reserve a static external IP address for the instance"
  type        = bool
  default     = false
}


