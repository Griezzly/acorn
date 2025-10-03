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

## Node Initialization

### Orchestrator Initialization

The orchestrator node uses a cloud-init configuration ([`cloud-init-orchestrator.yaml`](cloud-init-orchestrator.yaml)) to automatically set up the Oakestra root orchestrator on boot. The initialization process:

1. **Systemd Service**: Creates `oakestra-orchestrator-init.service` that runs [`orchestrator-init.sh`](../scripts/orchestrator-init.sh)
2. **Dependency Management**: Service waits for Docker and network to be ready before starting
3. **Environment Setup**: Configures Oakestra environment variables:
   - `SYSTEM_MANAGER_URL`: Private IP of orchestrator (10.0.1.10)
   - `CLUSTER_LOCATION`: Geolocation coordinates (detected from public IP or defaults to 0.0,0.0)
   - `CLUSTER_NAME`: Default `acorn-benchmark-cluster`
   - `OAKESTRA_BRANCH`: Repository branch (default: main)
4. **Docker Compose**: Starts Oakestra services using `1-DOC.yaml` (root orchestrator + single cluster)
5. **Health Checks**: Waits for System Manager API (port 10000) and verifies all containers are running
6. **Readiness Server**: Starts HTTP server on port 9999 to signal when orchestrator is ready for worker connections

**Key Services Started:**
- System Manager API: Port 10000 (Oakestra API)
- Dashboard: Port 80 (Web UI)
- Cluster Manager: Port 10007
- NetManager: Port 10008
- Readiness endpoint: Port 9999

All logs are written to `/var/log/oakestra-init.log`. The service automatically restarts on failure.

### Worker Node Initialization

Worker nodes use a simpler cloud-init process ([`cloud-init-worker.yaml`](cloud-init-worker.yaml)) that runs [`worker-init.sh`](../scripts/worker-init.sh) to connect to the orchestrator. The initialization process:

1. **Direct Script Execution**: Runs worker-init.sh directly in cloud-init's runcmd (no systemd service needed)
2. **Orchestrator Readiness Check**: Waits for orchestrator to be available before proceeding:
   - Checks readiness endpoint on port 9999
   - Falls back to checking System Manager port 10000
   - Timeout: 20 minutes (120 attempts x 10 seconds)
3. **NodeEngine Daemon**: Starts Oakestra NodeEngine with `-d` flag:
   - Command: `sudo NodeEngine -a 10.0.1.10 -d`
   - The `-d` flag automatically creates a systemd service (`nodeengine.service`)
   - Daemon process runs as `/bin/nodeengined`
4. **Verification**: Confirms nodeengined process is running or nodeengine.service is active

**Key Details:**
- Worker connects to orchestrator's private IP: `10.0.1.10`
- NodeEngine registers the worker with the Oakestra cluster
- Worker resources (CPU, memory) automatically reported to cluster
- Logs written to `/var/log/oakestra-worker-init.log`

The script completes and exits after starting NodeEngine daemon. The nodeengined process continues running independently managed by systemd.

## Verification

After deploying the infrastructure, verify the cluster is fully operational using the automated verification script:

```bash
cd terraform
../scripts/verify-cluster.sh
```

The script automatically:
1. Gets the orchestrator IP from Terraform output
2. Checks if the API docs endpoint is accessible (`http://<orchestrator_ip>:10000/api/docs`)
3. Authenticates with the Oakestra API (username: `Admin`, password: `Admin`)
4. Fetches cluster information from `/api/clusters/` endpoint
5. Verifies the number of active nodes matches the expected worker count
6. Displays cluster details (name, active nodes, CPU cores, memory)

**Example output (successful verification):**
```
[INFO] Orchestrator IP: 91.98.197.159
[INFO] Expected worker count: 1
[INFO] ✓ API docs endpoint is accessible
[INFO] ✓ Successfully authenticated
[INFO] Cluster Name: acorn-benchmark-cluster
[INFO] Active Nodes: 1
[INFO] Total CPU Cores: 2
[INFO] Total Memory: 1574 MB
[INFO] ✓ Cluster verification PASSED
[INFO] ✓ All 1 worker node(s) successfully connected
```

**Troubleshooting:**
- If verification fails, workers may still be initializing (wait 2-3 minutes after deployment)
- Check orchestrator logs: `ssh root@<orchestrator_ip> 'tail -f /var/log/oakestra-init.log'`
- Check worker logs: `ssh root@<worker_ip> 'tail -f /var/log/oakestra-worker-init.log'`
- The script provides helpful error messages with suggested commands for debugging

### Manual Verification

You can also verify manually by following the [Oakestra Agent context](../claude-context/oakestra-agent-context.md) to interact with the API directly.