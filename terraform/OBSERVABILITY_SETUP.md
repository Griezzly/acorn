# Observability Setup Summary

Complete observability stack for Oakestra worker nodes with centralized logging and metrics collection.

## Overview

This setup provides:
- **Container logs** → Loki (via Promtail)
- **System metrics** → Prometheus (via Node Exporter)
- **Visualization** → Grafana (dashboards for logs + metrics)

## Quick Setup

### 1. Configure Terraform Variables

Add to `terraform.tfvars`:

```hcl
loki_url = "your-mac.tailnet.ts.net"        # Your Loki Tailscale hostname
prometheus_url = "your-mac.tailnet.ts.net"  # Your Prometheus Tailscale hostname (optional)
```

### 2. Deploy Infrastructure

```bash
cd terraform
terraform apply
```

This automatically:
- Installs Promtail and Node Exporter on all worker nodes
- Configures them to start after Tailscale connects
- Begins collecting logs and metrics immediately

### 3. Configure Prometheus

Add worker nodes to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'oakestra-workers'
    scrape_interval: 5s
    static_configs:
      - targets:
          - 'thesis-test-worker-1.tailnet.ts.net:9100'
          - 'thesis-test-worker-2.tailnet.ts.net:9100'
```

Then restart: `docker restart prometheus`

### 4. Access Grafana

Open `http://localhost:3000` and:
1. Import Node Exporter dashboard (ID: 1860)
2. Query logs with LogQL
3. Query metrics with PromQL

## What Gets Collected

### Logs (Port 3100 → Loki)

- **Oakestra container logs** from containerd
- **NetManager logs** (network overlay)
- **NodeEngine logs** (orchestration)

### Metrics (Port 9100 → Prometheus)

- **CPU**: usage %, load averages, per-core stats
- **Memory**: used/free/available, swap
- **Disk I/O**: read/write rates, latency
- **Network**: bytes in/out, packets, errors

## Initialization Flow

```
Cloud-init (on boot)
  ├── Install packages (curl, jq, unzip)
  ├── Download Promtail binary → /usr/local/bin/promtail
  ├── Download Node Exporter binary → /usr/local/bin/node_exporter
  ├── Write config files:
  │   ├── /etc/promtail/config.yml
  │   ├── /etc/systemd/system/promtail.service
  │   └── /etc/systemd/system/node_exporter.service
  └── Run worker-init.sh
      ├── Wait for network
      ├── Connect to Tailscale ✓
      ├── Start Promtail ✓ (now can reach Loki)
      ├── Start Node Exporter ✓ (exposes metrics on :9100)
      ├── Wait for orchestrator
      └── Start Oakestra NodeEngine
```

## Key Features

### Timing Protection
- Promtail and Node Exporter start **after** Tailscale connects
- Prevents connection errors and retries
- Clean logs without spurious warnings

### Automatic Retry
- Promtail has built-in retry logic if Loki becomes unreachable
- Node Exporter just exposes metrics (no push, no failures)
- Systemd auto-restarts both services on failure

### Resource Efficient
- Promtail: ~50MB RAM
- Node Exporter: ~10MB RAM
- Negligible CPU usage

## Verification

### Check Services on Worker

```bash
ssh root@worker-ip

# Check Promtail
systemctl status promtail
curl http://localhost:9080/metrics  # Promtail metrics

# Check Node Exporter
systemctl status node_exporter
curl http://localhost:9100/metrics | head  # Node metrics

# Check Tailscale
tailscale status
```

### Check from Mac

```bash
# Test Promtail connectivity (should fail - Promtail doesn't expose HTTP)
# But Loki should receive logs

# Test Node Exporter connectivity
curl http://thesis-test-worker-1.tailnet.ts.net:9100/metrics | head

# Query Loki
curl "http://localhost:3100/loki/api/v1/label/job/values" | jq

# Query Prometheus
curl "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job=="oakestra-workers")'
```

## Example Queries

### Logs (LogQL in Grafana)

```logql
# All container logs
{job="oakestra-containers"}

# Errors from specific worker
{job="oakestra-containers", host="thesis-test-worker-1"} |= "error"

# NetManager network issues
{job="netmanager", level="ERROR"}
```

### Metrics (PromQL in Grafana)

```promql
# CPU usage %
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)

# Memory usage %
100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))

# Network traffic (bytes/sec)
rate(node_network_receive_bytes_total{device="eth0"}[1m])
```

## Documentation

- **[LOGGING.md](LOGGING.md)** - Complete Promtail/Loki logging guide
- **[METRICS.md](METRICS.md)** - Complete Node Exporter/Prometheus metrics guide
- **[terraform/README.md](README.md)** - Infrastructure deployment guide

## Troubleshooting

**Services not starting:**
- Check `/var/log/cloud-init-output.log` for installation errors
- Check `/var/log/oakestra-worker-init.log` for startup sequence
- Verify Tailscale is connected: `tailscale status`

**No logs in Loki:**
- Verify Promtail is running: `systemctl status promtail`
- Check Promtail can reach Loki: `curl http://<loki_url>:3100/ready`
- Check Promtail config: `cat /etc/promtail/config.yml`

**No metrics in Prometheus:**
- Verify Node Exporter is running: `systemctl status node_exporter`
- Test via Tailscale: `curl http://worker.tailnet.ts.net:9100/metrics`
- Check Prometheus scrape config and targets

**Old workers not updated:**
- Destroy and recreate: `terraform destroy -target=hcloud_server.worker && terraform apply`