# Acorn Benchmark Execution Guide

This guide covers executing distributed benchmarks with Acorn. It assumes you have already deployed the infrastructure using the instructions in [terraform/README.md](../terraform/README.md).

## Prerequisites

### Local Machine Requirements

Before running benchmarks, ensure your Mac has the following running:

1. **Docker Desktop** - For running Loki and Grafana
2. **Tailscale** - For secure connectivity to cloud nodes
3. **Loki** - Log aggregation backend (port 3100)
4. **Grafana** - Log visualization UI (port 3000)

### One-Time Setup on Your Mac

#### 1. Tailscale

Install and authenticate:
```bash
# Install Tailscale
brew install tailscale
tailscale up

# Get your Tailscale IP (needed for benchmark nodes)
tailscale ip -4
# Example: 100.77.231.113
```

#### 2. Loki (Log Aggregation)

Start Loki container:
```bash
docker run -d \
  --name loki \
  -p 3100:3100 \
  --restart unless-stopped \
  grafana/loki:latest \
  -config.file=/etc/loki/local-config.yaml

# Verify it's running
curl http://localhost:3100/ready
# Should return: ready
```

#### 3. Grafana (Log Visualization)

Start Grafana container:
```bash
docker run -d \
  --name grafana \
  -p 3000:3000 \
  --restart unless-stopped \
  -e "GF_SECURITY_ADMIN_PASSWORD=admin" \
  -e "GF_SECURITY_ADMIN_USER=admin" \
  grafana/grafana:latest
```

Configure Loki as datasource:
```bash
curl -X POST http://admin:admin@localhost:3000/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Loki",
    "type": "loki",
    "url": "http://host.docker.internal:3100",
    "access": "proxy",
    "basicAuth": false,
    "isDefault": true
  }'
```

Access Grafana at http://localhost:3000 (login: admin/admin).

---

## Running a Benchmark

### Overview

A benchmark execution involves:
1. **Orchestrator (Lair)**: Coordinates the benchmark, waits for nodes, distributes execution plans
2. **Workers (Acorn)**: Execute chaos engineering operations, send logs to Loki
3. **Your Mac**: Collects and visualizes logs via Loki/Grafana

### Step 1: Configure Target Node Count

Edit `lair/main.go` to match your infrastructure:

```go
const targetNodeCount = 4 // Total nodes (orchestrator counts as 1 + workers)
```

For example:
- 3 workers deployed ’ `targetNodeCount = 4`
- 1 worker deployed ’ `targetNodeCount = 2`

### Step 2: Start the Orchestrator

SSH to your orchestrator node:
```bash
# Get orchestrator IP from Terraform
cd terraform
terraform output -raw orchestrator_public_ipv4

# SSH to orchestrator
ssh root@<orchestrator-ip>
```

On the orchestrator node:
```bash
cd /path/to/acorn
go run ./lair
```

Expected output:
```
Orchestrator server listening on :50051
Waiting for 4 nodes to register. Currently: 0
```

### Step 3: Start Worker Nodes

For each worker, SSH and start the acorn process:

```bash
# SSH to worker
ssh root@<worker-ip>

# Start acorn (connects to orchestrator at 10.0.1.10)
cd /path/to/acorn
go run ./acorn --server 10.0.1.10:50051
```

As workers connect, the orchestrator logs will show:
```
Received node registration: worker-1 at 10.0.0.10
Received node registration: worker-2 at 10.0.0.11
Received node registration: worker-3 at 10.0.0.12
All 4 nodes registered!
```

### Step 4: Benchmark Execution

Once all nodes register, the benchmark automatically proceeds:

1. **Sync Phase**: Nodes synchronize clocks via NTP
2. **Plan Generation**: Orchestrator creates chaos plans based on infrastructure topology
3. **Plan Distribution**: Each node receives its execution plan
4. **Execution**: Nodes execute chaos operations synchronously:
   - Network chaos: IP blocking, traffic delays, packet loss
   - Resource chaos: CPU load, memory reservation
   - Monitoring: Continuous diagnostics (CPU, memory, network I/O)
5. **Log Collection**: Nodes push logs to Loki via Tailscale

### Execution Plan Format

Plans are timestamped operations in the format: `timestamp:action:args`

Example plan:
```
1000:block:10.0.0.10    # Block traffic to worker at 1000ms
2000:delay:150          # Add 150ms network delay at 2000ms
3000:loss:10            # Add 10% packet loss at 3000ms
4000:mem:512            # Reserve 512MB memory at 4000ms
5000:cpu:0.6            # Apply 60% CPU load at 5000ms
6000:unblock:10.0.0.10  # Unblock traffic at 6000ms
```

Plans are generated in `lair/networking.go:generateExecutionPlanForNode()` and automatically target other nodes in the cluster.

---

## Viewing Benchmark Results

### Grafana Explore

1. Open http://localhost:3000
2. Click **Explore** (compass icon) in left sidebar
3. Datasource is already set to **Loki**

### Essential Queries

**All benchmark logs:**
```logql
{job="benchmark_node"}
```

**Specific node:**
```logql
{job="benchmark_node", node_id="worker-1"}
```

**Benchmark lifecycle:**
```logql
{job="benchmark_node"} |= "BENCHMARK_START" or "BENCHMARK_END"
```

**Step execution:**
```logql
{job="benchmark_node"} |= "STEP_"
```

**System diagnostics:**
```logql
{job="benchmark_node"} |= "Diagnostics"
```

**Chaos operations:**
```logql
{job="benchmark_node"} |= "BlockIP" or "DelayTraffic" or "PacketLoss"
```

### Understanding Log Output

Logs use structured tags for parsing:

```
[BENCHMARK_START] node_id=worker-1 plan_start_time=1234567890 execution_start=1234567891
[STEP_START] timestamp=1234567892 action=block args=[10.0.0.10] scheduled_at=1000
BlockIP: blocked IP 10.0.0.10
[STEP_END] action=block duration_us=1234
Diagnostics - CPU: 45.23%, Mem: 32.10%, NetIn: 123456B, NetOut: 789012B
[BENCHMARK_END] node_id=worker-1 execution_end=1234567899 duration_ms=8000 steps_executed=6
```

**Key Metrics Available:**
- Execution duration (total and per-step)
- CPU usage (%)
- Memory usage (%)
- Network I/O (bytes in/out)
- Chaos operation success/failure
- Step timing accuracy

### Grafana Tips

- **Live tail**: Enable "Live" mode for real-time streaming
- **Time range**: Use time picker to focus on specific benchmark runs
- **Log context**: Click log lines to see surrounding context
- **Export**: Use Inspector to export as JSON/CSV

---

## Customizing Benchmarks

### Modifying Execution Plans

Edit `lair/networking.go:generateExecutionPlanForNode()` to create custom chaos scenarios:

```go
func generateExecutionPlanForNode(nodeIP string, targetIPs []string) (string, int64) {
    var steps []string

    // Example: Heavy network partition scenario
    if len(targetIPs) > 0 {
        steps = append(steps, fmt.Sprintf("500:block:%s", targetIPs[0]))
        steps = append(steps, "1000:delay:500")      // 500ms latency
        steps = append(steps, "2000:loss:50")        // 50% packet loss
        steps = append(steps, fmt.Sprintf("10000:unblock:%s", targetIPs[0]))
    }

    plan := strings.Join(steps, "\n")
    start := time.Now().Add(5 * time.Second).UnixMilli()
    return plan, start
}
```

### Adjusting Diagnostic Frequency

Edit `acorn/planexecuter.go:25`:

```go
ticker := time.NewTicker(100 * time.Millisecond) // Change from 5ms default
```

### Adding Custom Metrics

Add instrumentation in `acorn/planexecuter.go:Execute()`:

```go
pe.logCollector.Add(fmt.Sprintf("[CUSTOM_METRIC] my_value=%d", value))
```

---

## Troubleshooting

### No Logs in Grafana

Check Loki connectivity from cloud nodes:
```bash
# From a worker node
curl http://100.77.231.113:3100/ready
```

Verify Tailscale network:
```bash
# On your Mac
tailscale status
# Should show orchestrator and workers
```

Check acorn logs for errors:
```bash
# On worker node
# Look for "Successfully pushed logs to Loki" or errors
```

### Nodes Not Registering

Verify orchestrator is listening:
```bash
# On orchestrator
netstat -ln | grep 50051
```

Check worker connectivity:
```bash
# From worker
nc -zv 10.0.1.10 50051
```

### Container Management

```bash
# Check container status
docker ps --filter "name=loki" --filter "name=grafana"

# View logs
docker logs -f loki
docker logs -f grafana

# Restart containers
docker restart loki grafana

# Stop containers
docker stop loki grafana

# Start containers
docker start loki grafana
```

---

## Next Steps

- **Analyze metrics**: Create Grafana dashboards for key performance indicators
- **Scale experiments**: Increase worker count in Terraform and adjust `targetNodeCount`
- **Complex scenarios**: Design multi-stage chaos plans with different failure modes
- **Automate runs**: Script benchmark execution with different configurations