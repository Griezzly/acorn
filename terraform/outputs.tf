output "orchestrator_id" {
  description = "ID of the orchestrator server"
  value       = hcloud_server.orchestrator.id
}

output "orchestrator_name" {
  description = "Name of the orchestrator server"
  value       = hcloud_server.orchestrator.name
}

output "orchestrator_public_ipv4" {
  description = "Public IPv4 address of the orchestrator server"
  value       = hcloud_server.orchestrator.ipv4_address
}

output "orchestrator_private_ipv4" {
  description = "Private IPv4 address of the orchestrator server"
  value       = "10.0.1.10"  # Fixed IP from Terraform configuration
}

output "worker_ids" {
  description = "IDs of all worker servers"
  value       = [for worker in hcloud_server.worker : worker.id]
}

output "worker_names" {
  description = "Names of all worker servers"
  value       = [for worker in hcloud_server.worker : worker.name]
}

output "worker_public_ipv4s" {
  description = "Public IPv4 addresses of all worker servers"
  value       = [for worker in hcloud_server.worker : worker.ipv4_address]
}

output "worker_private_ipv4s" {
  description = "Private IPv4 addresses of all worker servers"
  value       = [for idx, worker in hcloud_server.worker : "10.0.0.${idx + 10}"]
}

output "workers_info" {
  description = "Complete information about all worker servers"
  value = {
    for idx, worker in hcloud_server.worker : worker.name => {
      id          = worker.id
      name        = worker.name
      public_ip   = worker.ipv4_address
      private_ip  = "10.0.0.${idx + 10}"
      worker_id   = idx + 1
    }
  }
}

output "network_id" {
  description = "ID of the private network"
  value       = hcloud_network.benchmark_network.id
}

output "network_ip_range" {
  description = "IP range of the private network"
  value       = hcloud_network.benchmark_network.ip_range
}

output "firewall_id" {
  description = "ID of the main firewall"
  value       = hcloud_firewall.benchmark_firewall.id
}

output "inter_node_firewall_id" {
  description = "ID of the inter-node communication firewall"
  value       = hcloud_firewall.inter_node_firewall.id
}