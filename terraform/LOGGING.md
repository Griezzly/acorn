# Centralized Logging with Loki and Promtail

This setup automatically configures Promtail on all worker nodes to scrape Oakestra container logs and forward them to a centralized Loki instance.

> **Note**: For performance metrics (CPU, memory, disk, network), see [METRICS.md](METRICS.md) for Node Exporter setup.

## Architecture

- **Loki**: Centralized log aggregation server (running on your host via Docker/Tailscale)
- **Promtail**: Log collector agent (automatically deployed on each worker node via cloud-init)
- **Grafana**: Dashboard for querying and visualizing logs (connect to your Loki instance)

## Configuration

### 1. Set Loki URL in terraform.tfvars

Add your Loki server's Tailscale hostname or IP to `terraform.tfvars`:

```hcl
loki_url = "your-tailscale-hostname"  # e.g., "macbook.tailnet-name.ts.net"
# or
loki_url = "100.x.x.x"  # Tailscale IP
```

### 2. Deploy Infrastructure

```bash
cd terraform
terraform apply
```

Promtail will be automatically installed via cloud-init and started after Tailscale connects to ensure connectivity to Loki.

**Initialization Order:**
1. Cloud-init installs Promtail binary and configuration
2. Worker init script connects to Tailscale
3. Promtail service starts and begins forwarding logs

## What Gets Logged

Promtail collects logs from:

1. **Oakestra Application Containers** (`job=oakestra-containers`)
   - Path: `/var/lib/containerd/io.containerd.grpc.v1.cri/containers/*/log/*.log`
   - Parses containerd CRI log format
   - Extracts: timestamp, stream (stdout/stderr), container_id, content

2. **Oakestra NetManager** (`job=netmanager`)
   - Path: `/var/log/oakestra/netmanager.log`
   - Network overlay management logs

3. **Oakestra NodeEngine** (`job=nodeengine`)
   - Path: `/var/log/oakestra/nodeengine.log`
   - Container orchestration logs

## Labels

Each log entry includes the following labels for filtering:

- `job`: Log source (oakestra-containers, netmanager, nodeengine)
- `host`: Worker hostname (e.g., thesis-test-worker-1)
- `stream`: stdout or stderr (containers only)
- `container_id`: Containerd container ID (containers only)
- `level`: Log level (netmanager/nodeengine only)

## Querying Logs in Grafana

### View all container logs from a specific worker

```logql
{job="oakestra-containers", host="thesis-test-worker-1"}
```

### Filter by container ID

```logql
{job="oakestra-containers", container_id="abc123..."}
```

### View only stderr logs

```logql
{job="oakestra-containers", stream="stderr"}
```

### Search for specific text in container logs

```logql
{job="oakestra-containers"} |= "error"
```

### View NetManager logs with ERROR level

```logql
{job="netmanager", level="ERROR"}
```

### Aggregate logs from all workers

```logql
{job="oakestra-containers"}
```

## Troubleshooting

### Check Promtail status on worker node

```bash
ssh root@worker-ip
systemctl status promtail
journalctl -u promtail -f
```

### Verify Promtail configuration

```bash
cat /etc/promtail/config.yml
```

### Check Promtail is sending logs

```bash
# Check Promtail metrics endpoint
curl http://localhost:9080/metrics
```

### Verify Loki is receiving logs

On your Loki host:

```bash
# Check recent log streams
curl -G -s "http://localhost:3100/loki/api/v1/label/job/values" | jq

# Query logs
curl -G -s "http://localhost:3100/loki/api/v1/query" --data-urlencode 'query={job="oakestra-containers"}' | jq
```

### Common Issues

**Promtail not starting:**
- Check if Loki URL is reachable from worker: `ping <loki_url>`
- Verify Tailscale is connected: `tailscale status`
- Check cloud-init logs: `cat /var/log/cloud-init-output.log`

**No container logs appearing:**
- Verify containers are running: `ctr -n oakestra containers ls`
- Check containerd log path exists: `ls -la /var/lib/containerd/io.containerd.grpc.v1.cri/containers/`
- Ensure Promtail has read permissions to containerd logs

**Old worker nodes not sending logs:**
- If workers were created before adding Promtail, destroy and recreate them:
  ```bash
  terraform destroy -target=hcloud_server.worker
  terraform apply
  ```

## Log Retention

Log retention is configured in your Loki instance. By default, the Promtail configuration batches logs:
- Batch wait: 1 second
- Batch size: 102400 bytes

Adjust in `terraform/promtail-config.yml` if needed.

## Performance Considerations

- Promtail runs with minimal resource overhead (~50MB RAM)
- Logs are compressed before sending to Loki
- Position file (`/tmp/positions.yaml`) tracks last read position to avoid duplicates
- Automatic restart on failure (systemd)