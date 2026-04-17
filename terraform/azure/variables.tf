variable "subscription_id" {
  description = "Variable not strictly needed if logged in via az cli, but good practice"
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region to deploy to"
  type        = string
  default     = "East US"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "starlake-data-stack-rg"
}

variable "vm_size" {
  description = "Size of the Virtual Machine"
  type        = string
  default     = "Standard_D4s_v3" # 4 vCPU, 16GB RAM for stack needs
}

variable "admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
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
  description = "Reserve a static Public IP address for the instance"
  type        = bool
  default     = false
}
