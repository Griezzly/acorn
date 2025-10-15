variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "orchestrator_name" {
  description = "Name of the orchestrator server"
  type        = string
  default     = "thesis-test-orchestrator"
}

variable "worker_count" {
  description = "Number of worker nodes to create"
  type        = number
  default     = 1
  
  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "Worker count must be between 1 and 10."
  }
}


variable "worker_name_prefix" {
  description = "Prefix for worker server names (will be suffixed with index)"
  type        = string
  default     = "thesis-test-worker"
}

variable "server_type" {
  description = "Server type for both nodes"
  type        = string
  default     = "cpx11"
}

variable "location" {
  description = "Location for the servers"
  type        = string
  default     = "nbg1"
}

variable "ssh_keys" {
  description = "List of SSH key names or IDs to be added to the servers"
  type        = list(string)
  default     = []
}

variable "tailscale_auth_key" {
  description = "Tailscale authentication key for joining the tailnet"
  type        = string
  sensitive   = true
  default     = ""
}