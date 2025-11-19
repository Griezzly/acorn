# Quick Start: Grafana Dashboards

This guide helps you quickly get started with the Oakestra Infrastructure and Benchmark dashboards.

## 🚀 Quick Setup (5 minutes)

### Step 1: Start Observability Stack

```bash
cd scripts
./setup-observability.sh
```

This automatically:
- ✅ Generates Prometheus configuration with worker targets
- ✅ Starts Prometheus, Loki, and Grafana via Docker Compose
- ✅ Configures Grafana datasources
- ✅ Verifies all services are healthy

**Expected output:**
```
✅ Observability Stack Setup Complete!

Services:
  Grafana:    http://localhost:3000 (admin/admin)
  Prometheus: http://localhost:9090
  Loki:       http://localhost:3100
```

### Step 2: Import Dashboards

1. Open **http://localhost:3000** in your browser
2. Login with `admin` / `admin`
3. Click the **"+"** icon → **"Import"**
4. Click **"Upload JSON file"**
5. Select `benchmarks/oakestra-infrastructure-dashboard.json`
6. Click **"Import"**

Repeat for the benchmark dashboard (`benchmarks/grafana-dashboard.json`) if needed.

### Step 3: Explore Your Infrastructure

You should now see:
- **Cluster health** (worker count, healthy/down nodes)
- **Real-time metrics** (CPU, memory, network, disk)
- **Container logs** from your Oakestra applications
- **NetManager and NodeEngine logs** for diagnostics

---

## 📊 What You'll See

### Oakestra Infrastructure Dashboard

**Top Row - Cluster Health:**
- Total Worker Nodes: 2
- Healthy Workers: 2
- Down Workers: 0
- Active Containers: Based on deployed apps
- Errors/Warnings: Any recent issues

**System Metrics:**
- CPU usage per worker (with 70%/90% thresholds)
- Memory usage per worker
- Network traffic (RX/TX)
- Disk usage

**Application Logs:**
- All container logs from Oakestra
- Separate stderr stream for errors
- Log rate visualization

**Oakestra Logs:**
- NetManager logs (networking layer)
- NodeEngine logs (worker agent)
- Error/warning highlighting

### Acorn Benchmark Dashboard

(For when you run benchmarks)

- Benchmark event timeline
- Chaos operations tracking
- Real-time metrics during execution
- Benchmark statistics

---

## 🔍 Common Queries

### Find Container Logs

**All logs from a specific app:**
```logql
{job="oakestra-containers"} |= "authservice"
```

**Container errors only:**
```logql
{job="oakestra-containers", stream="stderr"}
```

### Debug Network Issues

**Service registration events:**
```logql
{job="netmanager"} |= "registration"
```

**Track specific service IP:**
```logql
{job="netmanager"} |= "10.30.10.2"
```

### Monitor Worker Health

**Average CPU across all workers:**
```promql
avg(100 - (avg by (instance) (rate(node_cpu_seconds_total{job="oakestra-workers",mode="idle"}[1m])) * 100))
```

**Worker with highest memory usage:**
```promql
topk(1, 100 * (1 - (node_memory_MemAvailable_bytes{job="oakestra-workers"} / node_memory_MemTotal_bytes{job="oakestra-workers"})))
```

---

## 🛠️ Troubleshooting

### No Data in Prometheus Panels?

**Check targets:**
```bash
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="oakestra-workers")'
```

Should show both workers as "up".

**If targets are down:**
```bash
# Verify Node Exporter on workers
ssh root@<worker-tailscale-ip> systemctl status node_exporter

# Test metrics endpoint
ssh root@<worker-tailscale-ip> curl http://localhost:9100/metrics | head -20
```

### No Data in Loki Panels?

**Check Promtail on workers:**
```bash
ssh root@<worker-tailscale-ip> systemctl status promtail
```

**Verify Loki connectivity:**
```bash
ssh root@<worker-tailscale-ip> "curl -s http://$(tailscale ip -4):3100/ready"
```

Should return: `ready`

**Check Promtail logs:**
```bash
ssh root@<worker-tailscale-ip> journalctl -u promtail -f
```

Look for: `Successfully pushed logs to Loki`

### Container Logs Not Appearing?

**Check containerd logs exist:**
```bash
ssh root@<worker-tailscale-ip> "find /var/lib/containerd/io.containerd.grpc.v1.cri/containers/ -name '*.log' | head -5"
```

**Check Promtail permissions:**
```bash
ssh root@<worker-tailscale-ip> "sudo -u promtail ls /var/lib/containerd/io.containerd.grpc.v1.cri/containers/"
```

If permission denied:
```bash
ssh root@<worker-tailscale-ip> "chmod -R o+r /var/lib/containerd/io.containerd.grpc.v1.cri/"
```

---

## 📚 Next Steps

- **Detailed documentation**: See [DASHBOARD_SETUP.md](DASHBOARD_SETUP.md)
- **Deploy an application**: See [../service-slas/DEPLOYMENT_GUIDE.md](../service-slas/DEPLOYMENT_GUIDE.md)
- **Run a benchmark**: See [README.md](README.md)
- **Customize dashboards**: Add panels, create alerts, export data

---

## 🎯 Quick Links

- **Grafana**: http://localhost:3000 (admin/admin)
- **Prometheus UI**: http://localhost:9090
- **Prometheus Targets**: http://localhost:9090/targets
- **Loki Health**: http://localhost:3100/ready
- **Grafana Explore**: http://localhost:3000/explore

---

## 💡 Tips

1. **Enable auto-refresh** (5s) for real-time monitoring
2. **Use Explore** for ad-hoc queries before adding to dashboard
3. **Add filters** to focus on specific workers or containers
4. **Use time picker** to zoom into specific events
5. **Export panels as CSV** for deeper analysis
6. **Create alerts** for critical thresholds (CPU > 90%, errors, etc.)

Happy monitoring! 🎉
