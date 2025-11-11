terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# Network for private communication
resource "hcloud_network" "benchmark_network" {
  name     = "benchmark-network"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "benchmark_subnet" {
  network_id   = hcloud_network.benchmark_network.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.0.0/22"  # Expanded to cover 10.0.0.0 - 10.0.3.255
}

# Basic firewall rules for the benchmark setup (without dynamic IPs)
resource "hcloud_firewall" "benchmark_firewall" {
  name = "benchmark-firewall"

  # Allow traffic from static management networks
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22-50104"
    source_ips = [
      "10.18.0.64/26",
      "10.30.0.0/16",
      "143.177.17.185/32",
      "2001:4860:7:161f::fa/128"
    ]
  }

  # Allow internal network traffic (private network range)
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22-50104"
    source_ips = [
      "10.0.0.0/16"
    ]
  }

  # Allow UDP traffic for NTP/sync
  rule {
    direction = "in"
    protocol  = "udp"
    port      = "50103"
    source_ips = [
      "10.0.0.0/16"
    ]
  }

  # Allow WireGuard VPN from specific IP (port 51820/udp)
  # This allows Mac client to connect to worker nodes via VPN
  rule {
    direction = "in"
    protocol  = "udp"
    port      = "51820"
    source_ips = [
      "143.177.17.185/32"
    ]
  }
}

# Dynamic firewall rules for inter-node communication via public IPs
resource "hcloud_firewall" "inter_node_firewall" {
  name = "inter-node-communication"

  # Allow TCP traffic between orchestrator and all workers' public IPs
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22-50104"
    source_ips = concat(
      ["${hcloud_server.orchestrator.ipv4_address}/32"],
      [for worker in hcloud_server.worker : "${worker.ipv4_address}/32"]
    )
  }

  # Allow UDP traffic between orchestrator and all workers' public IPs
  rule {
    direction = "in"
    protocol  = "udp"
    port      = "50103"
    source_ips = concat(
      ["${hcloud_server.orchestrator.ipv4_address}/32"],
      [for worker in hcloud_server.worker : "${worker.ipv4_address}/32"]
    )
  }
}

# Orchestrator server (lair) - created from snapshot 304469121
resource "hcloud_server" "orchestrator" {
  name        = var.orchestrator_name
  server_type = var.orchestrator_server_type
  image       = "325116432"  # Oakestra Root Snap
  location    = var.location
  
  ssh_keys = var.ssh_keys
  
  firewall_ids = [hcloud_firewall.benchmark_firewall.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.benchmark_network.id
    ip         = "10.0.1.10"  # Orchestrator in separate subnet
  }

  user_data = base64encode(templatefile("${path.module}/cloud-init-orchestrator.yaml", {
    orchestrator_script = base64encode(file("${path.module}/../scripts/orchestrator-init.sh"))
    stable_compose_file = base64gzip(file("${path.module}/oakestra-docker-compose.yaml"))
    tailscale_auth_key  = var.tailscale_auth_key
  }))

  depends_on = [
    hcloud_network_subnet.benchmark_subnet
  ]

  labels = {
    role        = "orchestrator"
    environment = "benchmark"
  }
}

# Worker servers (acorn) - created from snapshot 233861285
resource "hcloud_server" "worker" {
  count       = var.worker_count
  name        = "${var.worker_name_prefix}-${count.index + 1}"
  server_type = var.worker_server_type
  image       = "325116417"  # thesis-test-node-1-1745851244
  location    = var.location
  
  ssh_keys = var.ssh_keys
  
  firewall_ids = [hcloud_firewall.benchmark_firewall.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.benchmark_network.id
    ip         = "10.0.0.${count.index + 10}"  # Start from .10, .11, .12, etc.
  }

  user_data = base64encode(templatefile("${path.module}/cloud-init-worker.yaml", {
    worker_script      = base64encode(file("${path.module}/../scripts/worker-init.sh"))
    worker_id          = count.index + 1
    tailscale_auth_key = var.tailscale_auth_key
    promtail_config    = base64encode(templatefile("${path.module}/promtail-config.yml", {
      loki_url         = var.loki_url
      worker_hostname  = "${var.worker_name_prefix}-${count.index + 1}"
    }))
  }))

  depends_on = [
    hcloud_network_subnet.benchmark_subnet,
    hcloud_server.orchestrator  # Ensure orchestrator is created first
  ]

  labels = {
    role        = "worker"
    environment = "benchmark"
    worker_id   = tostring(count.index + 1)
  }
}

# Attach the inter-node firewall to all servers (orchestrator + workers)
resource "hcloud_firewall_attachment" "inter_node_all" {
  firewall_id = hcloud_firewall.inter_node_firewall.id
  server_ids  = concat(
    [hcloud_server.orchestrator.id],
    [for worker in hcloud_server.worker : worker.id]
  )
}