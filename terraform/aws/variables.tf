variable "region" {
  description = "The AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The EC2 instance type"
  type        = string
  default     = "t3.xlarge" # Approx 4 vCPU, 16GB RAM for stack needs
}

variable "volume_size" {
  description = "Size of the root volume in GB"
  type        = number
  default     = 50
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
  description = "Reserve a static Elastic IP address for the instance"
  type        = bool
  default     = false
}

variable "public_key_path" {
  description = "Path to the public_key_path to be used to connect to the VM"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}
