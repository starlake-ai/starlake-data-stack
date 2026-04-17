variable "zone" {
  description = "Scaleway Zone"
  type        = string
  default     = "fr-par-1"
}

variable "region" {
  description = "Scaleway Region"
  type        = string
  default     = "fr-par"
}

variable "project_id" {
    description = "Scaleway Project ID"
    type        = string
    default     = "" # Optional if set via environment variable
}

variable "instance_type" {
  description = "Instance Type"
  type        = string
  default     = "DEV1-L" # 4 vCPU, 4GB RAM - Might need sizing up for full stack, GP1-M recommended for prod
}

variable "image" {
  description = "Instance Image"
  type        = string
  default     = "ubuntu_jammy" # Ubuntu 22.04
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
  description = "Reserve a flexible IP (failed IP)"
  type        = bool
  default     = false
}
