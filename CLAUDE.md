# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Acorn is a distributed benchmarking system for testing cloud-native microservice applications deployed on Oakestra (an edge-cloud orchestration platform). The system executes chaos engineering operations while measuring application performance and system behavior.

## Build and Development Commands

This is a Go-based distributed benchmark orchestration system. Common commands:

```bash
# Build the application
go build ./...

# Run the orchestrator (lair)
go run ./lair

# Run a benchmark node (acorn)
go run ./acorn --server <orchestrator-ip>:50051

# Trigger a benchmark (from local machine)
go run ./cmd/benchmark-trigger --server <orchestrator-ip>:50051

# Run tests
go test ./...

# Generate gRPC code from proto files
cd grpc && ./build-proto.sh

# Format code
go fmt ./...
```

## Architecture Overview

### Core Components

1. **Lair (Orchestrator)** - `lair/main.go`
   - Central coordinator running on port 50051
   - Manages node registration and synchronization
   - Generates and distributes execution plans to benchmark nodes
   - Waits for target node count before starting benchmark
   - Located at private IP `10.0.1.10` in Hetzner infrastructure

2. **Acorn (Benchmark Node)** - `acorn/main.go`
   - Worker nodes that execute benchmark plans
   - Run on port 60051
   - Connect to orchestrator as gRPC clients
   - Execute chaos engineering operations
   - Push logs to Loki (with filesystem fallback)
   - Located at private IPs `10.0.0.10+` in Hetzner infrastructure

3. **Benchmark Trigger** - `cmd/benchmark-trigger/main.go`
   - CLI tool to trigger benchmark execution via gRPC
   - Sends `StartBenchmark` command to orchestrator
   - Waits for acknowledgment

### Key Architecture Patterns

- **gRPC Communication**: All inter-service communication uses Protocol Buffers
  - `grpc/benchmark.proto` - Main orchestrator/node protocol
  - `grpc/request.proto` - Request/response definitions
- **Plan Execution**: Nodes receive timestamped execution plans as strings and parse them into actions
- **Log Aggregation**: Dual logging strategy:
  - Primary: Push to Loki via Tailscale network
  - Fallback: Local filesystem at `/home/carsten/workspace/acorn/loki_fallback.log`
- **Synchronization**:
  - Orchestrator waits for `targetNodeCount` nodes to register (set in `lair/main.go:18`)
  - NTP-based clock synchronization before execution
  - Coordinated execution start time across all nodes

### Execution Plan Format

Plans are newline-separated strings with format: `timestamp:action:args`

Example operations:
- `1000:block:192.168.1.1` - Block traffic to IP at 1000ms
- `2000:delay:100` - Add 100ms network delay at 2000ms
- `3000:loss:10` - Add 10% packet loss at 3000ms
- `4000:mem:512` - Reserve 512MB memory at 4000ms
- `5000:cpu:0.6` - Apply 60% CPU load at 5000ms
- `6000:unblock:192.168.1.1` - Unblock traffic at 6000ms

Plans are generated in `lair/networking.go:generateExecutionPlanForNode()`.

### Chaos Engineering Operations

The PlanExecutor (`acorn/planexecuter.go`) supports:

**Network Chaos:**
- IP blocking/unblocking via iptables
- Traffic delay via tc (traffic control)
- Packet loss injection
- Connection tracing and diagnostics

**Resource Chaos:**
- Memory reservation (allocates byte slices)
- CPU loading (busy loops to target utilization)

**Monitoring:**
- Continuous system diagnostics (CPU, memory, network I/O)
- Ping RTT measurements
- Network interface statistics

All operations require sudo privileges for iptables and tc commands.

### Infrastructure Stack

**Hetzner Cloud Infrastructure:**
- Orchestrator: 1 node at `10.0.1.10` (public IP from terraform output)
- Workers: 1-10 nodes at `10.0.0.10+` (scalable via `worker_count` variable)
- Private network: `10.0.0.0/16` with subnet `10.0.0.0/22`
- Dual firewall setup for security
- Server type: CPX11 (2 vCPU, 2GB RAM) by default

**Oakestra Platform:**
- Root orchestrator on orchestrator node (ports 10000, 10007, 10008)
- NodeEngine on worker nodes
- Dashboard on port 80
- Cluster name: `acorn-benchmark-cluster`

**Target Application:**
- Acme Air microservices (MongoDB, Auth Service, Main App)
- Deployed via `scripts/deploy-acmeair.sh`
- Accessible at `http://10.30.10.2:9080` (Oakestra overlay network)
- Configuration: `service-slas/acmeair.json`

**Observability:**
- Loki: Port 3100 (runs on local Mac via Tailscale)
- Grafana: Port 3000 (runs on local Mac)
- Log collection: `pkg/logcollector/logcollector.go`

## Project Structure

```
acorn/
├── acorn/              # Benchmark node (worker) implementation
│   ├── main.go         # Entry point, gRPC client setup
│   ├── server.go       # gRPC server for receiving plans
│   └── planexecuter.go # Executes chaos operations
├── lair/               # Orchestrator implementation
│   ├── main.go         # Entry point, gRPC server setup
│   ├── networking.go   # Plan generation logic
│   └── infra.go        # Infrastructure topology management
├── cmd/
│   └── benchmark-trigger/ # CLI tool to start benchmarks
├── grpc/               # Protocol Buffer definitions
│   ├── benchmark.proto # Main protocol
│   ├── request.proto   # Request types
│   └── *.pb.go        # Generated code
├── pkg/
│   └── logcollector/  # Log aggregation client
├── scripts/            # Deployment and management scripts
│   ├── deploy-acmeair.sh        # Deploy Acme Air to Oakestra
│   ├── run-benchmark.sh         # Automated benchmark execution
│   ├── verify-cluster.sh        # Verify Oakestra cluster health
│   ├── orchestrator-init.sh     # Orchestrator initialization
│   ├── worker-init.sh           # Worker initialization
│   ├── setup-vpn-access.sh      # Tailscale VPN setup
│   └── VPN_SETUP.md            # VPN configuration guide
├── service-slas/       # Application definitions for Oakestra
│   ├── acmeair.json              # Acme Air microservices
│   ├── ingress.json              # Nginx ingress controller
│   ├── deployment-config.yaml   # Deployment parameters
│   └── DEPLOYMENT_GUIDE.md      # Detailed deployment guide
├── terraform/          # Infrastructure as Code
│   ├── main.tf                   # Hetzner Cloud resources
│   ├── variables.tf              # Configuration variables
│   ├── outputs.tf                # Resource outputs
│   ├── cloud-init-orchestrator.yaml
│   ├── cloud-init-worker.yaml
│   └── README.md                 # Infrastructure documentation
└── benchmarks/         # Observability setup
    ├── grafana-dashboard.json    # Pre-built dashboard
    ├── DASHBOARD_SETUP.md        # Dashboard setup guide
    └── README.md                 # Benchmark execution guide
```

## Quick Start

### 1. Deploy Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Hetzner Cloud API token

terraform init
terraform apply
```

### 2. Verify Cluster

```bash
cd terraform
../scripts/verify-cluster.sh
```

This checks that the Oakestra cluster is operational and all workers are connected.

### 3. Deploy Application

```bash
cd terraform
../scripts/deploy-acmeair.sh
```

This deploys the Acme Air microservices to Oakestra.

### 4. Run Benchmark

**Option A: Automated (recommended)**
```bash
./scripts/run-benchmark.sh
```

This handles git pull, build, orchestrator/worker startup, and benchmark triggering.

**Option B: Manual**
```bash
# SSH to orchestrator
ssh root@$(cd terraform && terraform output -raw orchestrator_public_ipv4)
cd /home/carsten/workspace/acorn
go run ./lair

# SSH to each worker (in separate terminals)
ssh root@<worker-ip>
cd /home/carsten/workspace/acorn
go run ./acorn --server 10.0.1.10:50051

# Trigger from local machine
go run ./cmd/benchmark-trigger --server <orchestrator-public-ip>:50051
```

### 5. View Results

Access Grafana at `http://localhost:3000` (requires Loki/Grafana running locally via Docker - see `benchmarks/README.md`).

## Configuration

### Scaling Workers

Edit `terraform/terraform.tfvars`:
```hcl
worker_count = 3  # Deploy 3 workers
```

Then update `lair/main.go:18`:
```go
const targetNodeCount = 3  // Must match worker_count
```

Apply changes:
```bash
cd terraform
terraform apply
```

### Customizing Chaos Plans

Edit `lair/networking.go:generateExecutionPlanForNode()` to modify chaos scenarios.

### Adjusting Diagnostic Frequency

Edit `acorn/planexecuter.go:25`:
```go
ticker := time.NewTicker(100 * time.Millisecond) // Default is 5ms
```

## Key Scripts

- **`scripts/run-benchmark.sh`** - Full automated benchmark execution
  - Options: `--skip-pull`, `--skip-build`, `--collect-logs`
- **`scripts/deploy-acmeair.sh`** - Deploy application to Oakestra
  - Environment: `FORCE_REDEPLOY=true` for redeployment
- **`scripts/verify-cluster.sh`** - Verify cluster health and worker count
- **`scripts/setup-vpn-access.sh`** - Configure Tailscale VPN for log collection
- **`scripts/clear-known-hosts.sh`** - Clear SSH known_hosts when infrastructure changes

## Dependencies

**System Requirements:**
- Go 1.24+
- Terraform
- Docker (for local Loki/Grafana)
- Tailscale (for log collection)
- jq (for parsing Terraform outputs)

**Go Dependencies:**
- `google.golang.org/grpc` - gRPC framework
- `google.golang.org/protobuf` - Protocol Buffers
- `github.com/shirou/gopsutil` - System metrics
- `github.com/prometheus/client_golang` - Prometheus client

**External Services:**
- Hetzner Cloud (infrastructure)
- Oakestra (container orchestration)
- Loki (log aggregation)
- Grafana (visualization)
- Tailscale (VPN for log collection)

## Important Notes

- **Privileges**: Nodes require sudo for iptables/tc operations
- **Clock Sync**: NTP synchronization via pool.ntp.org before execution
- **Network**: All gRPC uses insecure mode (no TLS)
- **Logs**: Dual logging (Loki + filesystem fallback)
- **State**: Orchestrator must receive `StartBenchmark` gRPC call to begin execution
- **Cleanup**: Run `terraform destroy` when done to avoid cloud costs
- **Snapshots**: Infrastructure uses pre-configured Hetzner snapshots with Oakestra installed
- **Private Network**: Orchestrator at `10.0.1.10`, workers at `10.0.0.10+`
- **Log Locations**:
  - Orchestrator: `/tmp/lair.log`
  - Workers: `/tmp/acorn.log`
  - Fallback: `/home/carsten/workspace/acorn/loki_fallback.log`

## Documentation

- **Infrastructure**: `terraform/README.md` - Complete Terraform setup
- **Benchmarks**: `benchmarks/README.md` - Benchmark execution and Grafana setup
- **Deployment**: `service-slas/DEPLOYMENT_GUIDE.md` - Application deployment guide
- **Dashboard**: `benchmarks/DASHBOARD_SETUP.md` - Grafana dashboard configuration
- **VPN**: `scripts/VPN_SETUP.md` - Tailscale VPN setup for log collection

## Troubleshooting

**Nodes not registering:**
- Check orchestrator is listening: `netstat -ln | grep 50051`
- Check worker connectivity: `nc -zv 10.0.1.10 50051`
- Verify `targetNodeCount` matches deployed workers

**No logs in Grafana:**
- Verify Loki is running: `docker ps | grep loki`
- Check Tailscale status: `tailscale status`
- Test connectivity from worker: `curl http://<tailscale-ip>:3100/ready`

**Oakestra cluster issues:**
- Run `scripts/verify-cluster.sh` for diagnostics
- Check orchestrator logs: `ssh root@<ip> 'tail -f /var/log/oakestra-init.log'`
- Check worker logs: `ssh root@<ip> 'tail -f /var/log/oakestra-worker-init.log'`

**Application deployment failures:**
- Verify cluster is healthy first: `scripts/verify-cluster.sh`
- Check MongoDB is ready (requires 30s initialization time)
- Review deployment logs in script output
- Force redeploy: `FORCE_REDEPLOY=true scripts/deploy-acmeair.sh`