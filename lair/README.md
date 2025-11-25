# Lair - Benchmark Orchestrator

The Lair orchestrator is the central coordinator for the Acorn distributed benchmarking system. It manages benchmark node registration, synchronization, and distributes chaos engineering execution plans to worker nodes.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Benchmark Scenarios](#benchmark-scenarios)
- [Command-Line Flags](#command-line-flags)
- [Usage Examples](#usage-examples)
- [Extending with New Scenarios](#extending-with-new-scenarios)
- [Flow and Lifecycle](#flow-and-lifecycle)

## Overview

The orchestrator:
- Listens on port `50051` for node registrations
- Waits for a configurable number of nodes to register (set via `targetNodeCount` constant)
- Receives a `StartBenchmark` gRPC call to begin execution
- Generates scenario-based execution plans for each node
- Distributes plans to worker nodes via gRPC
- Pushes logs to Loki for observability

## Architecture

### Core Components

**BenchmarkScenario Interface** (`benchmarking.go`)
```go
type BenchmarkScenario interface {
    GenerateExecutionPlans(nodeIPs []string) map[string]string
    GetDuration() int64
    GetName() string
}
```

**ScenarioConfig** - Unified configuration struct for creating scenarios
```go
type ScenarioConfig struct {
    ScenarioType            string
    Duration                int64
    DisconnectNodeCount     int
    DisconnectDuration      int64
    FullDisconnect          bool
    DisconnectAmountPerNode int
}
```

**CreateScenario()** - Factory function that creates scenarios based on configuration

### Orchestration Flow

```
Node Registration
    ↓
Wait for targetNodeCount nodes
    ↓
Wait for StartBenchmark gRPC call
    ↓
Sync all nodes (NTP time sync)
    ↓
Create scenario from command-line flags
    ↓
Generate execution plans via scenario
    ↓
Distribute plans to nodes
    ↓
Push logs to Loki
```

## Benchmark Scenarios

### Available Scenarios

#### 1. Disconnect Scenario (`--scenario=disconnect`)

Simulates network partitions and node disconnections using iptables rules.

**Parameters:**
- `--disconnect-nodes`: Number of nodes that will disconnect (default: 1)
- `--disconnect-duration`: Duration of each disconnect in seconds (default: 10)
- `--disconnect-amount`: Number of times each node disconnects (default: 1)
- `--full-disconnect`: Whether to disconnect from ALL nodes (true) or a random subset (false) (default: true)
- `--duration`: Total benchmark duration in seconds (default: 60)

**Behavior:**
- Randomly selects N nodes to disconnect (where N = `disconnect-nodes`)
- Each selected node generates random disconnect events within the benchmark duration
- Disconnect events are distributed across time windows to avoid overlap
- **Full Disconnect**: Node blocks ALL other nodes (simulates complete network isolation)
- **Partial Disconnect**: Node blocks a random subset of other nodes (simulates partial network partition)
- Each disconnect is followed by automatic reconnection after the specified duration

**Example Execution Plan:**
```
# Node 10.0.0.10 with full disconnect at 5 seconds for 10 seconds
5000:block:10.0.0.11
5000:block:10.0.0.12
15000:unblock:10.0.0.11
15000:unblock:10.0.0.12
```

## Command-Line Flags

### Global Flags
- `--scenario=<type>` - Scenario type to run (default: "disconnect")
- `--duration=<seconds>` - Total benchmark duration in seconds (default: 60)

### Disconnect Scenario Flags
- `--disconnect-nodes=<count>` - Number of nodes to disconnect (default: 1)
- `--disconnect-duration=<seconds>` - Duration of each disconnect in seconds (default: 10)
- `--disconnect-amount=<count>` - Number of times each node disconnects (default: 1)
- `--full-disconnect=<bool>` - Full (true) or partial (false) disconnect (default: true)

## Usage Examples

### Basic Examples

**Default Configuration:**
```bash
# 1 node disconnects fully once for 10 seconds during a 60-second benchmark
go run ./lair
```

**Short Test:**
```bash
# Quick 30-second test with 1 node disconnecting for 5 seconds
go run ./lair --duration=30 --disconnect-duration=5
```

### Advanced Examples

**Multiple Disconnects:**
```bash
# 2 nodes disconnect fully, 3 times each, for 15 seconds over 120 seconds
go run ./lair \
  --disconnect-nodes=2 \
  --disconnect-amount=3 \
  --disconnect-duration=15 \
  --duration=120
```

**Partial Network Partition:**
```bash
# 1 node disconnects from random subset of nodes for 20 seconds
go run ./lair \
  --full-disconnect=false \
  --disconnect-nodes=1 \
  --disconnect-duration=20 \
  --duration=90
```

**Aggressive Chaos Testing:**
```bash
# All nodes (2) disconnect multiple times throughout a 3-minute test
go run ./lair \
  --disconnect-nodes=2 \
  --disconnect-amount=5 \
  --disconnect-duration=8 \
  --duration=180 \
  --full-disconnect=true
```

**Split-Brain Simulation:**
```bash
# Partial disconnects to simulate split-brain scenarios
go run ./lair \
  --full-disconnect=false \
  --disconnect-nodes=2 \
  --disconnect-amount=2 \
  --disconnect-duration=30 \
  --duration=120
```

### Production-Ready Scenarios

**Realistic Network Instability:**
```bash
# Simulates realistic network instability with brief disconnections
go run ./lair \
  --disconnect-nodes=1 \
  --disconnect-amount=3 \
  --disconnect-duration=5 \
  --duration=300 \
  --full-disconnect=false
```

**Extended Partition Testing:**
```bash
# Test recovery from extended network partitions
go run ./lair \
  --disconnect-nodes=1 \
  --disconnect-amount=1 \
  --disconnect-duration=60 \
  --duration=180 \
  --full-disconnect=true
```

## Extending with New Scenarios

The architecture is designed for easy extensibility. Here's how to add new scenario types:

### Step 1: Define Scenario Struct

Create a new scenario struct in `benchmarking.go`:

```go
type ResourceBenchmarkScenario struct {
    Duration int64   // in seconds
    CPULoad  float64 // 0.0 to 1.0
    MemoryMB int     // MB to reserve
}
```

### Step 2: Implement BenchmarkScenario Interface

```go
// GenerateExecutionPlans creates plans for resource stress testing
func (r *ResourceBenchmarkScenario) GenerateExecutionPlans(nodeIPs []string) map[string]string {
    plans := make(map[string]string)

    for _, nodeIP := range nodeIPs {
        var steps []string

        // Example: Apply CPU load at 5 seconds
        steps = append(steps, fmt.Sprintf("5000:cpu:%.2f", r.CPULoad))

        // Example: Reserve memory at 10 seconds
        steps = append(steps, fmt.Sprintf("10000:mem:%d", r.MemoryMB))

        plans[nodeIP] = strings.Join(steps, "\n")
    }

    return plans
}

func (r *ResourceBenchmarkScenario) GetDuration() int64 {
    return r.Duration
}

func (r *ResourceBenchmarkScenario) GetName() string {
    return "Resource Stress Test"
}
```

### Step 3: Add Configuration Fields

Update `ScenarioConfig` in `benchmarking.go`:

```go
type ScenarioConfig struct {
    // Common settings
    ScenarioType string
    Duration     int64

    // Disconnect scenario settings
    DisconnectNodeCount     int
    DisconnectDuration      int64
    FullDisconnect          bool
    DisconnectAmountPerNode int

    // Resource scenario settings (NEW)
    CPULoad  float64
    MemoryMB int
}
```

### Step 4: Update Factory Function

Add your scenario to `CreateScenario()`:

```go
func CreateScenario(config ScenarioConfig) (BenchmarkScenario, error) {
    switch config.ScenarioType {
    case "disconnect":
        return &DisconnectBenchmarkScenario{
            Duration:                config.Duration,
            DisconnectingNodeAmount: config.DisconnectNodeCount,
            DisconnectDuration:      config.DisconnectDuration,
            FullDisconnect:          config.FullDisconnect,
            DisconnectAmountPerNode: config.DisconnectAmountPerNode,
        }, nil
    case "resource": // NEW
        return &ResourceBenchmarkScenario{
            Duration: config.Duration,
            CPULoad:  config.CPULoad,
            MemoryMB: config.MemoryMB,
        }, nil
    default:
        return nil, fmt.Errorf("unknown scenario type: %s", config.ScenarioType)
    }
}
```

### Step 5: Add Command-Line Flags

Add flags to `main.go`:

```go
var (
    // Existing flags...
    scenarioType = flag.String("scenario", "disconnect", "Benchmark scenario type (disconnect, resource)")

    // Resource scenario flags (NEW)
    cpuLoad  = flag.Float64("cpu-load", 0.8, "CPU load for resource scenario (0.0-1.0)")
    memoryMB = flag.Int("memory-mb", 512, "Memory to reserve in MB (resource scenario)")
)
```

### Step 6: Update ScenarioConfig Creation

Update the config creation in `main()`:

```go
scenarioConfig := ScenarioConfig{
    ScenarioType:            *scenarioType,
    Duration:                *duration,
    DisconnectNodeCount:     *disconnectNodeCount,
    DisconnectDuration:      *disconnectDuration,
    FullDisconnect:          *fullDisconnect,
    DisconnectAmountPerNode: *disconnectAmountPerNode,
    // NEW
    CPULoad:                 *cpuLoad,
    MemoryMB:                *memoryMB,
}
```

### Step 7: Use Your New Scenario

```bash
go run ./lair --scenario=resource --cpu-load=0.9 --memory-mb=1024 --duration=120
```

## Flow and Lifecycle

### 1. Startup Phase
```
Start gRPC server on :50051
    ↓
Log: [ORCHESTRATOR_START]
    ↓
Wait for node registrations
```

### 2. Node Registration Phase
```
Nodes connect and register
    ↓
Log: [NODE_REGISTER] for each node
    ↓
Wait until len(nodes) >= targetNodeCount
    ↓
Log: [NODE_REGISTRATION_COMPLETE]
```

### 3. Start Signal Wait
```
Log: "Ready to start benchmark. Send StartBenchmark gRPC call to begin."
    ↓
Block on startSignal channel
    ↓
Receive StartBenchmark() gRPC call
    ↓
Log: [START_COMMAND_RECEIVED]
```

### 4. Synchronization Phase
```
Log: [SYNC_START]
    ↓
Connect to each node via gRPC
    ↓
Call SyncNode() on each node (NTP time sync)
    ↓
Log: [SYNC_SUCCESS] or [SYNC_ERROR] per node
    ↓
Log: [SYNC_COMPLETE]
```

### 5. Plan Generation Phase
```
Parse command-line flags
    ↓
Create ScenarioConfig
    ↓
Call CreateScenario(config)
    ↓
Log: [SCENARIO_SELECTED] with scenario name
    ↓
Collect node IPs from registered nodes
    ↓
Call scenario.GenerateExecutionPlans(nodeIPs)
    ↓
Log: [PLAN_GENERATION_START]
```

### 6. Plan Distribution Phase
```
For each node:
    Create ExecutionPlan with:
        - NodeId
        - Plan string (generated by scenario)
        - StartTime (current time + 5 seconds)
    ↓
    Log: [PLAN_SEND] with node details
    ↓
    Call SendExecutionPlan() via gRPC
    ↓
    Log: [PLAN_SEND_SUCCESS] or [PLAN_SEND_ERROR]
    ↓
Log: [ORCHESTRATION_COMPLETE]
```

### 7. Log Export Phase
```
Collect all logs from logCollector
    ↓
Create Loki pusher with labels:
    - job: benchmark_orchestrator
    - node_id: orchestrator
    ↓
Push logs to Loki at LOKI_URL
    ↓
Log: Success or failure message
    ↓
Block indefinitely (select {})
```

## Configuration

### Constants in Code

**`targetNodeCount`** (line 19, `main.go`)
```go
const targetNodeCount = 2 // Set this to how many nodes you want to wait for
```
Must match the number of worker nodes deployed.

### Environment Variables

**`LOKI_URL`**
- Loki push endpoint for log aggregation
- Default: `http://100.77.231.113:3100/loki/api/v1/push`
- Override: `export LOKI_URL=http://your-loki-ip:3100/loki/api/v1/push`

## Execution Plan Format

Plans are newline-separated strings with format: `timestamp:action:args`

**Format:** `<milliseconds>:<action>:<arguments>`

**Supported Actions:**
- `block:<ip>` - Block traffic to IP address
- `unblock:<ip>` - Unblock traffic to IP address
- `delay:<ms>` - Add network delay in milliseconds
- `loss:<percent>` - Add packet loss percentage
- `mem:<mb>` - Reserve memory in MB
- `cpu:<load>` - Apply CPU load (0.0-1.0)

**Example Plan:**
```
1000:block:10.0.0.11
5000:delay:150
10000:unblock:10.0.0.11
15000:mem:512
20000:cpu:0.8
```

## Testing

Run unit tests for scenario generation:
```bash
go test -v ./lair/...
```

All tests validate:
- Empty input handling
- Parameter bounds checking
- Timing constraints
- Block/unblock pairing
- Node self-exclusion
- Randomization behavior

## Troubleshooting

### Nodes Not Registering
**Symptom:** Orchestrator stuck at "Waiting for N nodes to register"

**Solutions:**
- Verify nodes are running: `ssh root@<worker-ip> 'ps aux | grep acorn'`
- Check network connectivity: `nc -zv <orchestrator-ip> 50051`
- Verify `targetNodeCount` matches deployed nodes
- Check node logs: `ssh root@<worker-ip> 'tail -f /tmp/acorn.log'`

### Benchmark Not Starting
**Symptom:** All nodes registered but benchmark doesn't execute

**Solutions:**
- Send StartBenchmark gRPC call: `go run ./cmd/benchmark-trigger --server <ip>:50051`
- Check orchestrator logs for errors
- Verify `StartBenchmark()` wasn't already called

### Sync Failures
**Symptom:** `[SYNC_ERROR]` messages in logs

**Solutions:**
- Verify NTP is installed on nodes: `ssh root@<worker-ip> 'which ntpdate'`
- Check NTP server reachability: `ntpdate -q pool.ntp.org`
- Ensure nodes have sudo privileges for time sync

### Plans Not Executing
**Symptom:** Plans distributed but chaos operations don't occur

**Solutions:**
- Verify nodes have sudo privileges for iptables/tc commands
- Check node logs for execution errors
- Verify plan format is correct (timestamp:action:args)
- Ensure plan timestamps are in milliseconds

## Best Practices

### Scenario Design
1. **Start Small**: Begin with single disconnects before complex scenarios
2. **Allow Recovery Time**: Ensure benchmark duration > sum of disconnect durations
3. **Avoid Overlap**: Disconnect amount should fit within duration/disconnect-duration
4. **Test Incrementally**: Increase chaos gradually to understand system limits

### Timing Considerations
1. Plans start 5 seconds after distribution (hardcoded buffer)
2. Disconnect events are distributed across time windows automatically
3. Reconnection always happens before benchmark ends
4. NTP sync ensures coordinated execution across nodes

### Observability
1. All orchestrator events are logged with structured prefixes: `[EVENT_TYPE]`
2. Logs are pushed to Loki for centralized analysis
3. Use Grafana dashboards to visualize benchmark execution
4. Node-level logs available at `/tmp/acorn.log` on workers

## Related Documentation

- **Main Project README**: `../README.md` - Overall project documentation
- **Benchmark Execution Guide**: `../benchmarks/README.md` - How to run and analyze benchmarks
- **Infrastructure Setup**: `../terraform/README.md` - Deployment and infrastructure
- **Worker Node Implementation**: `../acorn/README.md` - Acorn worker node details

## Future Enhancements

Planned scenario types:
- **Resource Scenarios**: CPU load, memory stress, disk I/O
- **Mixed Scenarios**: Combine network chaos with resource constraints
- **Traffic Shaping**: Bandwidth limits, jitter injection
- **Service-Level Chaos**: Target specific Oakestra services
- **Time-Based Scenarios**: Clock skew, time dilation