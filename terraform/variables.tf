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
  default     = 2
  
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

variable "worker_server_type" {
  description = "Server type for worker nodes"
  type        = string
  default     = "cpx11"
}

variable "orchestrator_server_type" {
  description = "Server type for the orchestrator node"
  type        = string
  default     = "cpx22"
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

variable "loki_url" {
  description = "Loki server URL (Tailscale hostname or IP) for centralized logging"
  type        = string
  default     = ""
}
