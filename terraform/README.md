# Acorn Benchmark Infrastructure

This Terraform configuration defines the infrastructure for running Acorn distributed benchmark tests on Hetzner Cloud.

## Architecture

The setup consists of:

- **Orchestrator Node** (`thesis-test-node-1`): Runs the Lair orchestrator on port 50051
  - Created from snapshot `304469121` (Oakestra Root Snap)
  - Private IP: `10.0.1.10` (separate subnet to avoid conflicts)
  
- **Worker Nodes** (scalable): Run Acorn benchmark nodes on port 60051  
  - Created from snapshot `233861285` (thesis-test-node-1-1745851244)
  - Private IPs: `10.0.0.10`, `10.0.0.11`, `10.0.0.12`, etc. (based on worker count)
  - Default: 1 worker, configurable up to 10 workers

- **Private Network**: `10.0.0.0/16` with subnet `10.0.0.0/22` in `eu-central` zone (supports up to 1024 IPs)
- **Dual Firewall Setup**: 
  - Basic firewall: Static management networks and private network traffic
  - Inter-node firewall: Dynamic rules for public IP communication between all nodes

## Prerequisites

1. [Terraform](https://terraform.io) installed
2. [Hetzner Cloud CLI](https://github.com/hetznercloud/cli) configured
3. Hetzner Cloud API token

## Usage

1. **Setup configuration**:
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your API token
   ```

2. **Initialize and plan**:
   ```bash
   terraform init
   terraform plan
   ```

3. **Deploy infrastructure**:
   ```bash
   terraform apply
   ```

4. **Access servers**:
   ```bash
   # SSH to orchestrator
   ssh root@$(terraform output -raw orchestrator_public_ipv4)
   
   # SSH to workers (example for worker 1)
   ssh root@$(terraform output -json worker_public_ipv4s | jq -r '.[0]')
   
   # List all worker IPs
   terraform output -json workers_info | jq -r '.[] | "\(.name): \(.public_ip)"'
   ```

5. **Destroy when done**:
   ```bash
   terraform destroy
   ```

## Outputs

The configuration provides these outputs:

**Orchestrator:**
- `orchestrator_public_ipv4` / `orchestrator_private_ipv4`: Orchestrator IP addresses
- `orchestrator_id`: Hetzner server ID

**Workers:**
- `worker_public_ipv4s` / `worker_private_ipv4s`: Arrays of all worker IP addresses
- `worker_ids` / `worker_names`: Arrays of worker server IDs and names
- `workers_info`: Complete worker details as a map

**Infrastructure:**
- `network_id`: Private network ID
- `firewall_id` / `inter_node_firewall_id`: Firewall rule IDs

## Scaling Workers

To change the number of workers:

```bash
# Edit terraform.tfvars
worker_count = 3  # Scale to 3 workers

# Apply changes
terraform plan
terraform apply
```

Worker naming follows the pattern: `{worker_name_prefix}-{number}`
- Default: `thesis-test-worker-1`, `thesis-test-worker-2`, etc.
- Private IPs: `10.0.0.10`, `10.0.0.11`, `10.0.0.12`, etc.

## Customization

Edit `variables.tf` or override in `terraform.tfvars`:

- `worker_count`: Number of worker nodes (1-10, default: 1)
- `worker_name_prefix`: Prefix for worker names (default: `thesis-test-worker`)
- `orchestrator_name`: Orchestrator server name
- `server_type`: Instance size (default: `cpx11`)
- `location`: Hetzner location (default: `nbg1`)
- `ssh_keys`: List of SSH key names to add

## Current State

This configuration recreates your existing setup:
- Servers: `thesis-test-node-1` (116.203.149.6) and `thesis-test-node-2` (167.235.134.239)
- Network: `network-1` (10.0.0.0/16)  
- Firewall: `firewall-1` with current rules

The snapshots preserve your configured benchmark environment.