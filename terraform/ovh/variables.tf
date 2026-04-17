variable "auth_url" {
  description = "OpenStack Auth URL"
  type        = string
  default     = "https://auth.cloud.ovh.net/v3/"
}

variable "region" {
  description = "OpenStack Region"
  type        = string
  default     = "GRA11"
}

variable "service_name" {
  description = "The OS Project ID (Tenant ID)"
  type        = string
}

variable "flavor_name" {
  description = "Instance Flavor Name"
  type        = string
  default     = "d2-8" # 8GB RAM, 2 vCPU
}

variable "image_name" {
  description = "Instance Image Name"
  type        = string
  default     = "Ubuntu 22.04"
}

variable "key_pair_name" {
  description = "Name of the Key Pair to use"
  type        = string
}

variable "network_name" {
  description = "Name of the network to attach to (usually Ext-Net)"
  type        = string
  default     = "Ext-Net"
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
