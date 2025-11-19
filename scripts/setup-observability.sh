#!/bin/bash
# Setup complete observability stack (Prometheus, Loki, Grafana) using Docker Compose
#
# This script:
# - Generates prometheus.yml with all worker node targets
# - Deploys Prometheus, Loki, and Grafana via docker-compose
# - Configures Grafana with datasources automatically
# - Exposes:
#   - Prometheus: http://localhost:9090
#   - Loki: http://localhost:3100
#   - Grafana: http://localhost:3000 (admin/admin)
#
# Prerequisites:
# - Terraform already applied in ../terraform/
# - Docker installed and running
# - Docker Compose installed
# - Tailscale connected and running
# - Workers deployed with Node Exporter and Promtail (automatic via cloud-init)
#
# Usage: ./setup-observability.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
BENCHMARKS_DIR="$SCRIPT_DIR/../benchmarks"
PROMETHEUS_CONFIG="$BENCHMARKS_DIR/prometheus.yml"
PROMETHEUS_TEMPLATE="$BENCHMARKS_DIR/prometheus.yml.template"
COMPOSE_FILE="$BENCHMARKS_DIR/docker-compose.yml"

echo "=========================================="
echo "  Oakestra Observability Stack Setup"
echo "=========================================="
echo ""

# Check prerequisites
echo "==> Checking prerequisites..."

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed"
    echo "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "❌ Error: Docker is not running"
    echo "Start Docker Desktop and try again"
    exit 1
fi
echo "✅ Docker is running"

# Check Docker Compose
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null 2>&1; then
    echo "❌ Error: Docker Compose is not installed"
    echo "Install Docker Compose or update Docker Desktop"
    exit 1
fi

# Detect compose command (docker-compose vs docker compose)
if docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi
echo "✅ Docker Compose is available ($COMPOSE_CMD)"

# Check Tailscale
if ! command -v tailscale &> /dev/null; then
    echo "❌ Error: Tailscale is not installed"
    echo "Install Tailscale: https://tailscale.com/download"
    exit 1
fi

if ! tailscale status &> /dev/null; then
    echo "❌ Error: Tailscale is not connected"
    echo "Run: tailscale up"
    exit 1
fi
echo "✅ Tailscale is connected"

# Check Terraform directory
if [ ! -d "$TERRAFORM_DIR" ]; then
    echo "❌ Error: Terraform directory not found at $TERRAFORM_DIR"
    exit 1
fi

# Check jq
if ! command -v jq &> /dev/null; then
    echo "⚠️  jq is not installed, installing via Homebrew..."
    brew install jq
fi
echo "✅ Prerequisites met"
echo ""

# Get worker info from Terraform
cd "$TERRAFORM_DIR"
echo "==> Getting worker information from Terraform..."

WORKER_COUNT=$(terraform output -json worker_names 2>/dev/null | jq '. | length')
if [ -z "$WORKER_COUNT" ] || [ "$WORKER_COUNT" -eq 0 ]; then
    echo "❌ Error: No workers found in Terraform output"
    echo "Make sure 'terraform apply' has been run successfully"
    exit 1
fi

echo "✅ Found $WORKER_COUNT worker(s)"
echo ""

# Get Tailscale worker IPs and hostnames
echo "==> Detecting worker nodes in Tailscale network..."

# Get all Tailscale machines that match acorn-worker pattern
# Using IPs instead of hostnames for better compatibility (MagicDNS may not be enabled)
TAILSCALE_WORKERS=$(tailscale status --json | jq -r '.Peer[] | select(.HostName | test("^acorn-worker-")) | "\(.TailscaleIPs[0])#\(.HostName)"' | sort)

if [ -z "$TAILSCALE_WORKERS" ]; then
    echo "⚠️  Warning: No acorn-worker machines found in Tailscale network"
    echo "Workers may still be initializing or have different names"
    echo ""
    echo "Current Tailscale machines:"
    tailscale status | head -20
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    # Fallback to empty list
    TAILSCALE_WORKER_COUNT=0
else
    TAILSCALE_WORKER_COUNT=$(echo "$TAILSCALE_WORKERS" | wc -l | tr -d ' ')
    echo "✅ Found $TAILSCALE_WORKER_COUNT worker(s) in Tailscale:"
    echo "$TAILSCALE_WORKERS" | while IFS='#' read -r ip hostname; do
        echo "  - $hostname ($ip)"
    done
fi

# Verify count matches Terraform
if [ "$TAILSCALE_WORKER_COUNT" -ne "$WORKER_COUNT" ]; then
    echo ""
    echo "⚠️  Warning: Tailscale worker count ($TAILSCALE_WORKER_COUNT) doesn't match Terraform ($WORKER_COUNT)"
    echo "Some workers may still be joining Tailscale network"
fi
echo ""

# Generate prometheus.yml
echo "==> Generating Prometheus configuration..."

if [ ! -f "$PROMETHEUS_TEMPLATE" ]; then
    echo "❌ Error: Prometheus template not found at $PROMETHEUS_TEMPLATE"
    exit 1
fi

# Copy template
cp "$PROMETHEUS_TEMPLATE" "$PROMETHEUS_CONFIG"

# Add worker targets dynamically (using Tailscale IPs)
echo "  Adding worker targets to prometheus.yml:"

if [ -n "$TAILSCALE_WORKERS" ]; then
    # Use Tailscale worker IPs
    # Build the targets section with proper indentation for Node Exporter (port 9100)
    NODE_EXPORTER_TARGETS=""
    # Build the targets section with proper indentation for cAdvisor (port 8080)
    CADVISOR_TARGETS=""

    while IFS='#' read -r ip hostname; do
        echo "    - $ip:9100 (Node Exporter - $hostname)"
        echo "    - $ip:8080 (cAdvisor - $hostname)"

        # Node Exporter targets
        if [ -z "$NODE_EXPORTER_TARGETS" ]; then
            NODE_EXPORTER_TARGETS="          - '$ip:9100'  # $hostname"
        else
            NODE_EXPORTER_TARGETS="${NODE_EXPORTER_TARGETS}\n          - '$ip:9100'  # $hostname"
        fi

        # cAdvisor targets
        if [ -z "$CADVISOR_TARGETS" ]; then
            CADVISOR_TARGETS="          - '$ip:8080'  # $hostname"
        else
            CADVISOR_TARGETS="${CADVISOR_TARGETS}\n          - '$ip:8080'  # $hostname"
        fi
    done <<< "$TAILSCALE_WORKERS"

    # Replace the placeholders with actual targets using sed
    sed "s|# WORKER_TARGETS_PLACEHOLDER|$NODE_EXPORTER_TARGETS|g" "$PROMETHEUS_CONFIG" > "$PROMETHEUS_CONFIG.tmp"
    mv "$PROMETHEUS_CONFIG.tmp" "$PROMETHEUS_CONFIG"
    sed "s|# CADVISOR_TARGETS_PLACEHOLDER|$CADVISOR_TARGETS|g" "$PROMETHEUS_CONFIG" > "$PROMETHEUS_CONFIG.tmp"
    mv "$PROMETHEUS_CONFIG.tmp" "$PROMETHEUS_CONFIG"
else
    echo "    (No Tailscale workers found - prometheus.yml will have empty targets)"
    echo "    You can add them manually later or re-run this script"
    # Remove the placeholder lines for empty targets
    sed '/# WORKER_TARGETS_PLACEHOLDER/d' "$PROMETHEUS_CONFIG" > "$PROMETHEUS_CONFIG.tmp"
    mv "$PROMETHEUS_CONFIG.tmp" "$PROMETHEUS_CONFIG"
    sed '/# CADVISOR_TARGETS_PLACEHOLDER/d' "$PROMETHEUS_CONFIG" > "$PROMETHEUS_CONFIG.tmp"
    mv "$PROMETHEUS_CONFIG.tmp" "$PROMETHEUS_CONFIG"
fi

echo "✅ Configuration generated at $PROMETHEUS_CONFIG"
echo ""

# Stop existing containers if running
echo "==> Checking for existing observability stack..."
cd "$BENCHMARKS_DIR"

if $COMPOSE_CMD ps 2>/dev/null | grep -q "Up"; then
    echo "Stopping existing containers..."
    $COMPOSE_CMD down
    echo "✅ Existing containers stopped"
else
    echo "ℹ️  No existing containers found"
fi
echo ""

# Start observability stack
echo "==> Starting observability stack with Docker Compose..."
$COMPOSE_CMD up -d

echo "✅ Containers started"
echo ""

# Wait for services to be ready
echo "==> Waiting for services to be ready..."

# Wait for Loki
echo -n "  Loki... "
for i in {1..30}; do
    if curl -s http://localhost:3100/ready > /dev/null 2>&1; then
        echo "✅"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Timeout"
        echo "Check logs with: cd $BENCHMARKS_DIR && $COMPOSE_CMD logs loki"
        exit 1
    fi
    sleep 1
done

# Wait for Prometheus
echo -n "  Prometheus... "
for i in {1..30}; do
    if curl -s http://localhost:9090/-/ready > /dev/null 2>&1; then
        echo "✅"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Timeout"
        echo "Check logs with: cd $BENCHMARKS_DIR && $COMPOSE_CMD logs prometheus"
        exit 1
    fi
    sleep 1
done

# Wait for Grafana
echo -n "  Grafana... "
for i in {1..30}; do
    if curl -s http://localhost:3000/api/health > /dev/null 2>&1; then
        echo "✅"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Timeout"
        echo "Check logs with: cd $BENCHMARKS_DIR && $COMPOSE_CMD logs grafana"
        exit 1
    fi
    sleep 1
done

echo ""

# Verify Prometheus targets
echo "==> Verifying Prometheus scrape targets..."
sleep 3  # Give Prometheus time to initialize scraping

TARGETS=$(curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="oakestra-workers") | "\(.labels.instance) - \(.health)"')

if [ -z "$TARGETS" ]; then
    echo "⚠️  Warning: No worker targets found yet"
    echo "This may take a few moments. Check status at http://localhost:9090/targets"
else
    echo "$TARGETS" | while read -r target; do
        if echo "$target" | grep -q "up"; then
            echo "  ✅ $target"
        else
            echo "  ⚠️  $target (may still be initializing)"
        fi
    done
fi
echo ""

# Verify Grafana datasources
echo "==> Verifying Grafana datasources..."
DATASOURCES=$(curl -s http://admin:admin@localhost:3000/api/datasources | jq -r '.[].name' 2>/dev/null || echo "")

if echo "$DATASOURCES" | grep -q "Loki"; then
    echo "  ✅ Loki datasource configured"
else
    echo "  ⚠️  Loki datasource not found (may still be initializing)"
fi

if echo "$DATASOURCES" | grep -q "Prometheus"; then
    echo "  ✅ Prometheus datasource configured"
else
    echo "  ⚠️  Prometheus datasource not found (may still be initializing)"
fi
echo ""

echo "=========================================="
echo "✅ Observability Stack Setup Complete!"
echo "=========================================="
echo ""
echo "Services:"
echo "  Grafana:         http://localhost:3000 (admin/admin)"
echo "  Prometheus:      http://localhost:9090"
echo "  Loki:            http://localhost:3100"
echo ""
echo "Grafana Datasources:"
echo "  - Loki (default) - for logs from Promtail"
echo "  - Prometheus - for metrics from Node Exporter"
echo ""
echo "Quick Links:"
echo "  Prometheus Targets:  http://localhost:9090/targets"
echo "  Grafana Explore:     http://localhost:3000/explore"
echo "  Grafana Datasources: http://localhost:3000/datasources"
echo ""
echo "Configuration Files:"
echo "  Docker Compose:      $COMPOSE_FILE"
echo "  Prometheus Config:   $PROMETHEUS_CONFIG"
echo "  Grafana Provisioning: $BENCHMARKS_DIR/grafana-provisioning/"
echo ""
echo "Container Management:"
echo "  View all logs:       cd $BENCHMARKS_DIR && $COMPOSE_CMD logs -f"
echo "  View specific logs:  cd $BENCHMARKS_DIR && $COMPOSE_CMD logs -f <service>"
echo "  Stop all services:   cd $BENCHMARKS_DIR && $COMPOSE_CMD down"
echo "  Restart all:         cd $BENCHMARKS_DIR && $COMPOSE_CMD restart"
echo "  Check status:        cd $BENCHMARKS_DIR && $COMPOSE_CMD ps"
echo ""
echo "Example Queries:"
echo ""
echo "  Loki (LogQL) - View all container logs:"
echo "    {job=\"oakestra-containers\"}"
echo ""
echo "  Prometheus (PromQL) - Worker CPU usage:"
echo "    100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)"
echo ""
echo "  Prometheus (PromQL) - Worker memory usage:"
echo "    100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))"
echo ""
echo "Next Steps:"
echo "  1. Open Grafana at http://localhost:3000"
echo "  2. Import the benchmark dashboard from benchmarks/grafana-dashboard.json"
echo "  3. Check Prometheus targets are UP at http://localhost:9090/targets"
echo "  4. Run a benchmark and view logs/metrics in real-time"
echo ""
echo "Troubleshooting:"
echo "  - If targets show DOWN, verify workers are accessible:"
echo "    ping acorn-worker-1"
echo "  - Test Node Exporter directly:"
echo "    curl http://acorn-worker-1:9100/metrics"
echo "  - Check worker Node Exporter service:"
echo "    ssh root@<worker-ip> systemctl status node_exporter"
echo "  - View container logs:"
echo "    cd $BENCHMARKS_DIR && $COMPOSE_CMD logs <service-name>"
echo ""