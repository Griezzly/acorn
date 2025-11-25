# Grafana Dashboard Setup Guide

This guide covers importing and using both the Oakestra Infrastructure Dashboard and Acorn Benchmark Dashboard in Grafana.

## Available Dashboards

### 1. Oakestra Infrastructure Dashboard
**File**: `oakestra-infrastructure-dashboard.json`

Monitors your Oakestra cluster infrastructure with:
- **Worker node metrics** (CPU, memory, network, disk) from Prometheus/Node Exporter
- **Container logs** from Oakestra applications (via Promtail → Loki)
- **NetManager logs** for networking diagnostics
- **NodeEngine logs** for worker agent monitoring
- **Real-time alerts** for errors and warnings

### 2. Acorn Benchmark Dashboard
**File**: `grafana-dashboard.json`

Monitors benchmark execution with:

### 📊 Panels Included

1. **Benchmark Event Timeline** - Shows all benchmark events (start/end, steps, chaos operations)
2. **CPU Usage (%)** - Real-time CPU utilization per node (collected every 5ms)
3. **Memory Usage (%)** - Real-time memory utilization per node
4. **Network Traffic (RX/TX)** - Incoming/outgoing network traffic rates
5. **Memory Usage (Bytes)** - Absolute memory consumption
6. **Orchestrator Logs** - Full orchestrator event stream
7. **Statistics** - Quick stats showing:
   - Benchmarks Started
   - Benchmarks Completed
   - Network Blocks Applied
   - Nodes Registered

### 📈 Key Features

- **High-resolution metrics**: CPU, memory, and network data collected every 5ms
- **Correlated events**: Event timeline synchronized with metrics graphs
- **Multi-node view**: Compare metrics across all worker nodes
- **Auto-refresh**: Dashboard refreshes every 5 seconds
- **Historical data**: View last 15 minutes by default (adjustable)

---

## Prerequisites

Ensure you have completed the observability stack setup:

```bash
cd scripts
./setup-observability.sh
```

This sets up:
- ✅ Prometheus (port 9090) - scraping worker metrics
- ✅ Loki (port 3100) - receiving logs from Promtail
- ✅ Grafana (port 3000) - visualization with auto-configured datasources

---

## Importing Dashboards

### Method 1: Using Grafana UI (Recommended)

1. Open Grafana at http://localhost:3000
2. Login with `admin`/`admin` (you'll be prompted to change password on first login)
3. Click the **"+"** icon in left sidebar → **"Import"**
4. Click **"Upload JSON file"**
5. Select the dashboard JSON file:
   - For Oakestra Infrastructure: `benchmarks/oakestra-infrastructure-dashboard.json`
   - For Acorn Benchmark: `benchmarks/grafana-dashboard.json`
6. Configure datasources:
   - Select **"Prometheus"** for Prometheus queries (auto-detected)
   - Select **"Loki"** for Loki/LogQL queries (auto-detected)
7. Click **"Import"**

### Method 2: Using API

```bash
# From project root
curl -X POST \
  -H "Content-Type: application/json" \
  -d @benchmarks/grafana-dashboard.json \
  http://admin:admin@localhost:3000/api/dashboards/db
```

### Method 3: Copy-Paste JSON

1. Open Grafana at http://localhost:3000
2. Click **"+"** → **"Import"**
3. Open `benchmarks/grafana-dashboard.json` in a text editor
4. Copy the entire JSON content
5. Paste into the **"Import via panel json"** text area
6. Click **"Load"**
7. Select **"Loki"** as datasource
8. Click **"Import"**

---

## Using the Oakestra Infrastructure Dashboard

### Dashboard Overview

The dashboard is organized into **5 sections**:

1. **Cluster Overview** - High-level health and statistics
2. **Worker Node Metrics** - Real-time system metrics from Prometheus
3. **Oakestra Container Logs** - Application logs from containerd
4. **Oakestra NetManager** - Networking layer diagnostics
5. **Oakestra NodeEngine** - Worker agent monitoring

### Section 1: Cluster Overview

**Top Stats Row:**
- **Total Worker Nodes**: Count of all registered workers
- **Healthy Workers**: Workers with `up{job="oakestra-workers"} == 1`
- **Down Workers**: Workers with `up{job="oakestra-workers"} == 0`
- **Active Containers**: Containers generating logs in the last 5 minutes
- **Errors/Warnings**: Count of ERROR/WARN logs from NetManager and NodeEngine (last 5m)

### Section 2: Worker Node Metrics (Prometheus)

Real-time system metrics from Node Exporter:

**CPU Usage by Worker**
```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{job="oakestra-workers",mode="idle"}[1m])) * 100)
```
- Shows per-worker CPU utilization
- Thresholds: Yellow at 70%, Red at 90%

**Memory Usage by Worker**
```promql
100 * (1 - (node_memory_MemAvailable_bytes{job="oakestra-workers"} / node_memory_MemTotal_bytes{job="oakestra-workers"}))
```
- Shows per-worker memory pressure
- Thresholds: Yellow at 70%, Red at 90%

**Network Traffic (RX/TX)**
- Separate lines for receive (green) and transmit (blue, inverted)
- Excludes virtual interfaces (lo, veth, docker, br-)
- Unit: Bits per second (binBps)

**Disk Usage by Worker**
- Shows root filesystem usage (`/`)
- Thresholds: Yellow at 70%, Red at 90%

### Section 3: Oakestra Container Logs

Application container logs from Oakestra (via Promtail):

**All Container Logs**
- Shows logs from all containers managed by Oakestra
- Source: `/var/lib/containerd/io.containerd.grpc.v1.cri/containers/*/log/*.log`
- Labels: `job`, `host`, `container_id`, `stream` (stdout/stderr)

**Container Error Stream (stderr)**
- Filters for `stream="stderr"` to show only error output
- Useful for debugging application failures

**Container Log Rate by Host**
- Bar chart showing log volume per worker
- Helps identify noisy containers or log storms

### Section 4: Oakestra NetManager

Networking layer diagnostics:

**NetManager Logs (All Levels)**
- Full NetManager logs from `/var/log/oakestra/netmanager.log`
- Includes INFO, WARN, ERROR levels
- Parsed with timestamp and level extraction

**NetManager Errors & Warnings**
- Filtered view: `{job="netmanager"} |~ "ERROR|WARN"`
- Critical networking issues and warnings

**NetManager Log Rate by Level**
- Stacked bar chart showing ERROR (red), WARN (yellow), INFO levels
- Per-host breakdown

### Section 5: Oakestra NodeEngine

Worker agent diagnostics:

**NodeEngine Logs (All Levels)**
- Full NodeEngine logs from `/var/log/oakestra/nodeengine.log`
- Container lifecycle, resource management, cluster communication

**NodeEngine Errors & Warnings**
- Filtered view: `{job="nodeengine"} |~ "ERROR|WARN"`
- Worker agent issues

**NodeEngine Log Rate by Level**
- Stacked bar chart showing ERROR (red), WARN (yellow), INFO levels
- Per-host breakdown

### Useful Queries for Oakestra Infrastructure

**Container Logs:**
```logql
# All logs from a specific container
{job="oakestra-containers", container_id="YOUR_CONTAINER_ID"}

# Acme Air Auth Service logs
{job="oakestra-containers"} |= "authservice"

# Container errors only
{job="oakestra-containers", stream="stderr"}
```

**NetManager Logs:**
```logql
# Service registration events
{job="netmanager"} |= "registration"

# Network policy changes
{job="netmanager"} |~ "Outgoing packet|Incoming packet"

# Specific service IP
{job="netmanager"} |= "10.30.10.2"
```

**NodeEngine Logs:**
```logql
# Container lifecycle
{job="nodeengine"} |~ "Starting|Stopping|Created|Destroyed"

# Resource allocation
{job="nodeengine"} |~ "CPU|Memory|Disk"
```

**Prometheus Metrics:**
```promql
# Average CPU across all workers
avg(100 - (avg by (instance) (rate(node_cpu_seconds_total{job="oakestra-workers",mode="idle"}[1m])) * 100))

# Total network traffic
sum(rate(node_network_receive_bytes_total{job="oakestra-workers"}[1m])) + sum(rate(node_network_transmit_bytes_total{job="oakestra-workers"}[1m]))

# Worker with highest memory usage
topk(1, 100 * (1 - (node_memory_MemAvailable_bytes{job="oakestra-workers"} / node_memory_MemTotal_bytes{job="oakestra-workers"})))
```

### Example Workflows

**Debugging a Failing Container:**
1. Go to **Container Error Stream** panel
2. Filter by container ID or search for error keywords
3. Click log line to expand full context
4. Use **Show context** to see surrounding logs
5. Cross-reference with **NetManager** logs if networking-related

**Investigating Network Issues:**
1. Check **NetManager Errors & Warnings** for recent issues
2. Search for service IP: `{job="netmanager"} |= "10.30.10.2"`
3. Look for "Outgoing packet" or "registration" events
4. Cross-check worker **Network Traffic** panel for anomalies

**Performance Analysis:**
1. Open **CPU Usage** and **Memory Usage** panels
2. Identify workers with high utilization
3. Check **Container Log Rate** to see if specific containers are causing load
4. Use **Disk Usage** to identify storage issues

---

## Using the Acorn Benchmark Dashboard

### Quick Start

1. **Start your benchmark** (see [README.md](README.md))
2. **Open the dashboard** in Grafana
3. **Adjust time range** if needed (top-right corner)
4. **Enable auto-refresh** (already set to 5s)

### Reading the Metrics

#### CPU Usage Panel
```logql
{job="benchmark_node"} |= "WORKER_METRIC" | regexp "cpu_percent=(?P<cpu>[0-9.]+)"
```
- Shows CPU load percentage per node
- Legend displays: mean and max values
- Expect spikes during `cpu` chaos operations

#### Memory Usage Panels
```logql
# Percentage
{job="benchmark_node"} |= "WORKER_METRIC" | regexp "mem_percent=(?P<mem>[0-9.]+)"

# Absolute bytes
{job="benchmark_node"} |= "WORKER_METRIC" | regexp "mem_bytes=(?P<mem_bytes>[0-9]+)"
```
- Monitor memory consumption during benchmark
- Expect increases during `mem` (ReserveMemory) operations

#### Network Traffic Panel
```logql
# RX (receive)
rate({job="benchmark_node"} |= "WORKER_METRIC" | regexp "net_rx_bytes=(?P<net_rx>[0-9]+)" [1s])

# TX (transmit)
rate({job="benchmark_node"} |= "WORKER_METRIC" | regexp "net_tx_bytes=(?P<net_tx>[0-9]+)" [1s])
```
- Shows network throughput in bytes per second
- Green = RX (incoming), Blue = TX (outgoing)
- Drops expected during `block`, `delay`, or `loss` operations

### Analyzing a Benchmark Run

1. **Find benchmark start**: Look for `[BENCHMARK_START]` in Event Timeline
2. **Track chaos operations**: Watch for:
   - `BlockIP: blocked IP X.X.X.X`
   - `DelayTraffic: applied Xms delay`
   - `PacketLoss: applied X% packet loss`
   - `LoadCPU: applying X% load`
3. **Correlate with metrics**: Observe corresponding changes in CPU/memory/network graphs
4. **Verify completion**: Look for `[BENCHMARK_END]` with execution summary

### Example Analysis Flow

```
Timeline View:
  14:30:00 → [BENCHMARK_START] node_id=worker-1
  14:30:01 → BlockIP: blocked IP 10.0.0.11
  14:30:02 → LoadCPU: applying 80.00% load on 4 cores
  14:30:07 → [BENCHMARK_END] duration_ms=7000

CPU Graph:
  14:30:02 → Sharp spike to ~80% (LoadCPU triggered)
  14:30:07 → Drop back to baseline

Network Graph:
  14:30:01 → TX rate drops to ~0 (BlockIP effect)
  14:30:08 → TX rate recovers
```

## Customizing the Dashboard

### Adding Custom Panels

1. Click **"Add panel"** (top-right)
2. Select **"Add a new panel"**
3. Choose **Loki** as datasource
4. Enter your LogQL query
5. Adjust visualization settings
6. Click **"Apply"**

### Useful LogQL Queries

**Filter by specific node:**
```logql
{job="benchmark_node", node_id="worker-1"}
```

**Only chaos operations:**
```logql
{job="benchmark_node"} |= "BlockIP" or "DelayTraffic" or "PacketLoss"
```

**Step execution timing:**
```logql
{job="benchmark_node"} |= "STEP_" | regexp "duration_us=(?P<duration>[0-9]+)"
```

**Benchmark execution duration:**
```logql
{job="benchmark_node"} |= "BENCHMARK_END" | regexp "duration_ms=(?P<duration>[0-9]+)"
```

**Only errors/warnings:**
```logql
{job="benchmark_node"} |~ "error|failed|warning"
```

### Modifying Time Ranges

- **Default**: Last 15 minutes
- **Quick ranges**: Top-right time picker → "Last 5m", "Last 1h", etc.
- **Custom range**: Click calendar icon → Select start/end times
- **Live tail**: Select "Last 5 minutes" + enable auto-refresh

## Troubleshooting

### No Data Showing

**Check Loki datasource:**
```bash
curl http://localhost:3100/ready
# Should return: ready
```

**Verify logs are reaching Loki:**
```bash
# Query Loki API directly
curl -G -s "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={job="benchmark_node"}' | jq
```

**Check benchmark nodes are pushing logs:**
- Look in node logs for "Successfully pushed logs to Loki"
- Check `/tmp/acorn.log` on worker nodes for errors

### Metrics Not Parsing

If metrics show "No data" but logs appear:

1. **Verify metric format** in logs matches regex patterns
2. **Check for parsing errors**: Click panel → Edit → Query inspector
3. **Validate regex**: Test in Grafana Explore with `__error__=""` filter

### Dashboard Not Importing

**If JSON import fails:**
- Ensure JSON is valid (check with `jq . grafana-dashboard.json`)
- Remove any BOM or special characters
- Try Method 3 (copy-paste) as fallback

**If datasource missing:**
```bash
# Add Loki datasource via API
curl -X POST http://admin:admin@localhost:3000/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Loki",
    "type": "loki",
    "url": "http://localhost:3100",
    "access": "proxy",
    "isDefault": true
  }'
```

## Advanced Usage

### Alerting

Create alerts on key metrics:

1. Edit a panel → Alert tab → Create alert rule
2. Set threshold (e.g., CPU > 90% for 30s)
3. Configure notification channel (Slack, email, etc.)

### Variables

Add dashboard variables for filtering:

1. Dashboard settings (gear icon) → Variables → Add variable
2. Name: `node_id`
3. Type: Query
4. Query: `label_values(node_id)`
5. Use in queries: `{node_id="$node_id"}`

### Annotations

Mark specific events on graphs:

1. Dashboard settings → Annotations → Add annotation query
2. Datasource: Loki
3. Query: `{job="benchmark_node"} |= "BENCHMARK_START"`
4. Tag: `benchmark-start`

## Exporting Results

### Export Dashboard as JSON

1. Dashboard settings (gear icon) → JSON Model
2. Copy JSON → Save to file
3. Share with team or check into version control

### Export Panel Data

1. Click panel title → Inspect → Data
2. Download as CSV for analysis in Excel/Python
3. Use Inspector → Query to see raw LogQL results

### Screenshot Panels

1. Click panel title → Share → Snapshot
2. Set expiration time
3. Copy link or download image

## Next Steps

- Create custom dashboards for specific scenarios
- Set up alerting for critical metrics
- Export data for post-benchmark analysis
- Integrate with CI/CD pipelines for automated benchmarking

## References

- [Loki LogQL Documentation](https://grafana.com/docs/loki/latest/logql/)
- [Grafana Dashboard Documentation](https://grafana.com/docs/grafana/latest/dashboards/)
- [Acorn Benchmark README](README.md)