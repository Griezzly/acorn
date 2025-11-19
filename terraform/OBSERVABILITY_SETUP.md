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
loki_url = "macbookpro"        # Your Loki Tailscale hostname
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

### 3. Setup Observability Stack (Prometheus, Loki, Grafana)

Run the automated setup script:

```bash
cd scripts
./setup-observability.sh
```

This automatically:
- Generates `prometheus.yml` with all worker targets
- Deploys Prometheus, Loki, and Grafana via Docker Compose
- Configures Grafana datasources automatically
- Configures 30-day metric retention
- Verifies connectivity to all workers

**What gets deployed:**
- **Prometheus**: Metrics collection (port 9090)
- **Loki**: Log aggregation (port 3100)
- **Grafana**: Visualization UI (port 3000, admin/admin)

All services run in a Docker network and can communicate with each other.

### 4. Access Grafana

Open http://localhost:3000 (login: admin/admin) and:
1. Datasources are pre-configured (Loki and Prometheus)
2. Import Node Exporter dashboard (ID: 1860) for metrics
3. Import custom benchmark dashboard from `benchmarks/grafana-dashboard.json`
4. Query logs with LogQL in Explore
5. Query metrics with PromQL in Explore

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
curl http://acorn-worker-1:9100/metrics | head

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

## Docker Compose Management

All observability services are managed via Docker Compose in the `benchmarks/` directory.

### Common Commands

```bash
cd benchmarks

# View status of all containers
docker-compose ps

# View logs from all services
docker-compose logs -f

# View logs from specific service
docker-compose logs -f prometheus
docker-compose logs -f loki
docker-compose logs -f grafana

# Restart all services
docker-compose restart

# Restart specific service
docker-compose restart prometheus

# Stop all services
docker-compose down

# Start all services
docker-compose up -d

# Stop and remove all data (including volumes)
docker-compose down -v
```

### Updating Configuration

If you modify `prometheus.yml` or add more workers:

```bash
cd benchmarks

# Reload Prometheus configuration without restart
curl -X POST http://localhost:9090/-/reload

# Or restart Prometheus container
docker-compose restart prometheus
```

## Troubleshooting

**Docker Compose not found:**
- Install Docker Desktop which includes Docker Compose
- Or install standalone: `brew install docker-compose`

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
- Test via Tailscale: `curl http://acorn-worker-1:9100/metrics`
- Check Prometheus scrape config and targets at http://localhost:9090/targets

**Old workers not updated:**
- Destroy and recreate: `terraform destroy -target=hcloud_server.worker && terraform apply`