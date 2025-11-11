# Performance Metrics Collection with Node Exporter and Prometheus

This setup automatically deploys Node Exporter on all worker nodes to collect system performance metrics (CPU, memory, disk, network) and makes them available to Prometheus for storage and Grafana for visualization.

## Architecture

- **Node Exporter**: Lightweight metrics exporter running on each worker node (port 9100)
- **Prometheus**: Time-series database for metrics storage (running on your host via Docker/Tailscale)
- **Grafana**: Dashboard for querying and visualizing metrics (connect to your Prometheus instance)

## Quick Start

### 1. Deploy Worker Nodes with Node Exporter

Node Exporter is automatically installed via cloud-init when you deploy workers:

```bash
cd terraform
terraform apply
```

**Initialization Order:**
1. Cloud-init installs Node Exporter binary and systemd service
2. Worker init script connects to Tailscale
3. Node Exporter service starts and exposes metrics on port 9100

### 2. Configure Prometheus to Scrape Worker Metrics

You need to add the worker nodes to your Prometheus scrape configuration.

#### Option A: Manual Configuration

Edit your `prometheus.yml` and add:

```yaml
scrape_configs:
  - job_name: 'oakestra-workers'
    scrape_interval: 5s
    static_configs:
      - targets:
          - 'thesis-test-worker-1.tailnet.ts.net:9100'
          - 'thesis-test-worker-2.tailnet.ts.net:9100'
          # Add more workers as needed
```

#### Option B: Use Terraform Output

After deploying, get the worker Tailscale hostnames:

```bash
cd terraform
terraform output -json workers_info | jq -r '.[] | "        - \"\(.name).tailnet.ts.net:9100\""'
```

Copy the output into your Prometheus configuration.

### 3. Restart Prometheus

```bash
docker restart prometheus
# or if running as a service
systemctl restart prometheus
```

### 4. Verify Metrics Collection

Check that Prometheus is scraping metrics:

```bash
# Check Prometheus targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="oakestra-workers")'

# Query a sample metric
curl 'http://localhost:9090/api/v1/query?query=node_cpu_seconds_total' | jq
```

## Available Metrics

Node Exporter provides hundreds of metrics. Here are the most useful for benchmarking:

### CPU Metrics

- `node_cpu_seconds_total` - Total CPU time per mode (user, system, idle, iowait, etc.)
- `node_load1`, `node_load5`, `node_load15` - System load averages
- `process_cpu_seconds_total` - Per-process CPU usage

### Memory Metrics

- `node_memory_MemTotal_bytes` - Total physical memory
- `node_memory_MemFree_bytes` - Free memory
- `node_memory_MemAvailable_bytes` - Available memory (includes cache/buffers)
- `node_memory_Buffers_bytes` - Memory used for buffers
- `node_memory_Cached_bytes` - Memory used for cache
- `node_memory_SwapTotal_bytes` - Total swap space
- `node_memory_SwapFree_bytes` - Free swap space

### Disk Metrics

- `node_disk_io_time_seconds_total` - Disk I/O time
- `node_disk_read_bytes_total` - Bytes read from disk
- `node_disk_written_bytes_total` - Bytes written to disk
- `node_filesystem_avail_bytes` - Available filesystem space
- `node_filesystem_size_bytes` - Total filesystem size

### Network Metrics

- `node_network_receive_bytes_total` - Bytes received per interface
- `node_network_transmit_bytes_total` - Bytes transmitted per interface
- `node_network_receive_packets_total` - Packets received per interface
- `node_network_transmit_packets_total` - Packets transmitted per interface
- `node_network_receive_errs_total` - Receive errors
- `node_network_transmit_errs_total` - Transmit errors

### System Metrics

- `node_time_seconds` - Current system time (useful for checking clock sync)
- `node_boot_time_seconds` - System boot time
- `node_context_switches_total` - Context switches
- `node_forks_total` - Process forks

## Useful PromQL Queries

### CPU Usage Percentage

```promql
# Average CPU usage across all cores
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)

# Per-core CPU usage
100 - (avg by (instance, cpu) (rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)
```

### Memory Usage Percentage

```promql
# Memory utilization percentage
100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))

# Actual used memory (excluding cache/buffers)
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
```

### Disk I/O Rate

```promql
# Disk read rate (bytes/sec)
rate(node_disk_read_bytes_total[1m])

# Disk write rate (bytes/sec)
rate(node_disk_written_bytes_total[1m])
```

### Network Traffic Rate

```promql
# Network receive rate (bytes/sec) for eth0
rate(node_network_receive_bytes_total{device="eth0"}[1m])

# Network transmit rate (bytes/sec) for eth0
rate(node_network_transmit_bytes_total{device="eth0"}[1m])
```

### System Load

```promql
# 1-minute load average
node_load1

# Load average per CPU
node_load1 / count(node_cpu_seconds_total{mode="idle"}) by (instance)
```

## Grafana Dashboards

### Pre-built Node Exporter Dashboard

Import the official Node Exporter dashboard into Grafana:

1. Go to Grafana → Dashboards → Import
2. Enter dashboard ID: **1860** (Node Exporter Full)
3. Select your Prometheus data source
4. Click Import

This provides comprehensive system metrics visualization.

### Custom Dashboard for Benchmarking

Create a custom dashboard with panels for:

1. **CPU Usage Over Time** - Line graph showing CPU % for all workers
2. **Memory Usage Over Time** - Line graph showing memory % for all workers
3. **Network Traffic** - Area graph showing bytes in/out for each worker
4. **Disk I/O** - Stacked area showing read/write rates
5. **System Load** - Line graph showing load1/5/15 averages

Example panel JSON is available in `benchmarks/grafana-dashboard.json`.

## Correlating with Benchmark Events

To correlate metrics with benchmark execution:

1. Use Grafana's **Annotations** feature to mark benchmark start/stop times
2. Query logs and metrics in the same time range
3. Use the `node_time_seconds` metric to verify time synchronization

Example annotation query in Grafana:

```logql
# Mark when chaos operations start (from Loki logs)
{job="oakestra-containers"} |= "Executing chaos operation"
```

## Troubleshooting

### Node Exporter not running

Check status on worker node:

```bash
ssh root@worker-ip
systemctl status node_exporter
journalctl -u node_exporter -f
```

### Prometheus not scraping metrics

**Check connectivity from Prometheus host:**

```bash
# Test if Node Exporter is reachable via Tailscale
curl http://thesis-test-worker-1.tailnet.ts.net:9100/metrics
```

**Check Prometheus targets:**

```bash
curl http://localhost:9090/api/v1/targets | jq
```

Look for targets with `job="oakestra-workers"` and check their `health` status.

### Metrics missing or incomplete

**Verify Node Exporter is exposing metrics:**

```bash
ssh root@worker-ip
curl http://localhost:9100/metrics | grep node_cpu_seconds_total
```

**Check firewall rules:**

Node Exporter runs on port 9100. Ensure this port is accessible via Tailscale.

### High cardinality warnings

Node Exporter can produce many metrics. If Prometheus shows high cardinality warnings:

- Disable unused collectors using `--no-collector.<name>` flags in the systemd service
- Adjust `scrape_interval` to reduce data points (e.g., from 5s to 15s)

## Performance Considerations

- **Scrape Interval**: 5 seconds provides detailed time-series but increases storage. Use 15s or 30s for longer retention.
- **Retention**: Configure Prometheus retention based on your needs (default is 15 days).
- **Resource Usage**: Node Exporter uses ~10MB RAM and negligible CPU.

## Example: Comparing CPU Load During Chaos Operations

1. **Deploy workers and start benchmark**
2. **Query CPU usage during chaos**:
   ```promql
   rate(node_cpu_seconds_total{mode!="idle"}[1m])
   ```
3. **Filter by time range** in Grafana to match benchmark execution window
4. **Overlay with logs** showing which chaos operations were active

This allows you to see exactly how CPU load changes when you inject network delays, packet loss, or other chaos.

## Advanced: Exporting Metrics for Analysis

Export metrics to CSV for statistical analysis:

```bash
# Query Prometheus and export to CSV
curl -G 'http://localhost:9090/api/v1/query_range' \
  --data-urlencode 'query=rate(node_cpu_seconds_total{mode!="idle"}[1m])' \
  --data-urlencode 'start=2025-01-10T10:00:00Z' \
  --data-urlencode 'end=2025-01-10T11:00:00Z' \
  --data-urlencode 'step=5s' \
  | jq -r '.data.result[] | "\(.metric.instance),\(.metric.cpu),\(.values[] | "\(.[0]),\(.[1])")"' \
  > cpu_metrics.csv
```

## Next Steps

- Configure alerting in Prometheus for high CPU/memory usage
- Create Grafana dashboards tailored to your benchmark scenarios
- Integrate metrics with your benchmark result analysis
- Export metrics to InfluxDB or other time-series databases for long-term storage