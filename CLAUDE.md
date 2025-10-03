# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

This is a Go-based distributed benchmark orchestration system. Common commands:

```bash
# Build the application
go build ./...

# Run the orchestrator (lair)
go run ./lair

# Run a benchmark node (acorn)  
go run ./acorn

# Run tests
go test ./...

# Generate gRPC code from proto files
cd grpc && ./build-proto.sh

# Format code
go fmt ./...

# Run linting
golint ./...
```

## Architecture Overview

Acorn is a distributed benchmarking system with two main components:

### Core Components

1. **Lair (Orchestrator)** - `lair/main.go`
   - Central coordinator running on port 50051
   - Manages node registration and synchronization
   - Distributes execution plans to benchmark nodes
   - Collects logs from nodes after execution

2. **Acorn (Benchmark Node)** - `acorn/main.go`
   - Worker nodes that execute benchmark plans
   - Runs on port 60051 
   - Connects to orchestrator as gRPC client
   - Executes network chaos engineering operations

### Key Architecture Patterns

- **gRPC Communication**: All inter-service communication uses Protocol Buffers defined in `grpc/benchmark.proto`
- **Plan Execution**: Nodes receive timestamped execution plans as strings and parse them into actions
- **Log Aggregation**: Dual logging to both Loki (remote) and local filesystem fallback
- **Synchronization**: Orchestrator waits for target node count before distributing plans

### Execution Plan Format

Plans are newline-separated strings with format: `timestamp:action:args`
- `1000:block:192.168.1.1` - Block traffic to IP at 1000ms
- `2000:delay:100` - Add 100ms network delay at 2000ms  
- `3000:cpu:0.8` - Apply 80% CPU load at 3000ms

### Chaos Engineering Operations

The PlanExecutor (`acorn/planexecuter.go`) supports:
- **Network**: IP blocking, traffic delay, packet loss via iptables/tc
- **Resource**: Memory reservation, CPU loading
- **Monitoring**: System diagnostics, connection tracing, ping RTT

### Service Dependencies

- **MongoDB**: Required for acmeair service benchmarks (see service-slas/)
- **Loki**: Optional log aggregation endpoint
- **NTP**: Clock synchronization via pool.ntp.org

### Configuration

- Node target count: Set `targetNodeCount` in `lair/main.go:16`
- Network interface: Defaults to `eth0` in traffic control operations
- Loki endpoint: Configure in `acorn/server.go:69`

## Benchmark Experiment Setup

### Infrastructure Deployment

This project includes Infrastructure as Code (IaC) using Terraform to deploy scalable benchmark infrastructure on Hetzner Cloud.

#### Quick Setup

1. **Deploy Infrastructure**:
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your Hetzner Cloud API token
   
   terraform init
   terraform plan
   terraform apply
   ```

2. **Scale Workers** (optional):
   ```bash
   # Edit terraform.tfvars
   worker_count = 3  # Deploy 3 worker nodes
   
   terraform apply
   ```

3. **Access Servers**:
   ```bash
   # SSH to orchestrator
   ssh root@$(terraform output -raw orchestrator_public_ipv4)
   
   # SSH to first worker
   ssh root@$(terraform output -json worker_public_ipv4s | jq -r '.[0]')
   
   # List all worker IPs
   terraform output -json workers_info | jq -r '.[] | "\(.name): \(.public_ip)"'
   ```

#### Infrastructure Details

The Terraform configuration creates:
- **1 Orchestrator Node**: Runs Lair on `10.0.1.10` (port 50051)
- **N Worker Nodes**: Run Acorn on `10.0.0.10+` (port 60051)
- **Scalable Design**: 1-10 workers supported out-of-box
- **Network Security**: Dual firewall setup with dynamic public IP rules
- **Pre-configured Snapshots**: Nodes boot from tested benchmark snapshots

For complete infrastructure documentation, see: [terraform/README.md](terraform/README.md)

#### Experiment Execution

1. **Start Orchestrator**:
   ```bash
   # On orchestrator node
   cd /path/to/acorn
   go run ./lair
   ```

2. **Start Workers**:
   ```bash
   # On each worker node
   cd /path/to/acorn
   go run ./acorn --server <orchestrator-ip>:50051
   ```

3. **Monitor Progress**:
   - Orchestrator waits for `targetNodeCount` workers to connect
   - Execution plans are distributed and executed synchronously
   - Logs are collected from all nodes post-execution

#### Cleanup

```bash
# Destroy infrastructure when done
terraform destroy
```

## Important Notes

- Nodes require sudo privileges for iptables and tc network operations
- Clock synchronization happens during node sync phase before plan execution
- All gRPC connections use insecure mode (no TLS)
- Memory reservations are allocated as byte slices and held during execution
- Log collection happens asynchronously after plan completion