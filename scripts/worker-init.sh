#!/bin/bash

# Oakestra Worker Node Initialization Script
# This script waits for the orchestrator to be ready before starting worker services

set -e

LOG_FILE="/var/log/oakestra-worker-init.log"
ORCHESTRATOR_IP="10.0.1.10"  # Fixed IP from Terraform config
READINESS_PORT="9999"
ORCHESTRATOR_PORT="10000"    # Default Oakestra orchestrator port

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Wait for system to be ready
wait_for_system() {
    log "Waiting for system to be ready..."
    sleep 30  # Allow system to fully boot

    # Wait for network to be available
    until ping -c 1 8.8.8.8 >/dev/null 2>&1; do
        log "Waiting for network connectivity..."
        sleep 5
    done
    log "Network is ready"
}

# Initialize Tailscale
init_tailscale() {
    log "Initializing Tailscale..."

    # Check if tailscale is already installed
    if ! command -v tailscale >/dev/null 2>&1; then
        log "ERROR: Tailscale not found - should be pre-installed in snapshot"
        return 1
    fi

    log "Tailscale binary found"

    # Authenticate with Tailscale using auth key from environment
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        log "Authenticating with Tailscale..."
        tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="acorn-worker-${WORKER_ID}" --accept-routes

        if [ $? -eq 0 ]; then
            log "Tailscale authentication successful"

            # Get Tailscale IP
            TAILSCALE_IP=$(tailscale ip -4)
            log "Tailscale IP: $TAILSCALE_IP"
        else
            log "ERROR: Tailscale authentication failed"
            return 1
        fi
    else
        log "WARNING: TAILSCALE_AUTH_KEY not set, skipping Tailscale setup"
    fi
}

# Wait for orchestrator to be ready
wait_for_orchestrator() {
    log "Waiting for orchestrator at $ORCHESTRATOR_IP to be ready..."
    
    local max_attempts=120  # 20 minutes timeout
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt/$max_attempts: Checking orchestrator readiness..."
        
        # Check readiness endpoint
        if curl -f --connect-timeout 5 "http://$ORCHESTRATOR_IP:$READINESS_PORT" >/dev/null 2>&1; then
            log "Orchestrator readiness check passed"
            break
        fi
        
        # Also check if orchestrator service port is available as fallback
        if nc -z "$ORCHESTRATOR_IP" "$ORCHESTRATOR_PORT" 2>/dev/null; then
            log "Orchestrator service port is available"
            break
        fi
        
        log "Orchestrator not ready yet, waiting..."
        sleep 10
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log "ERROR: Orchestrator did not become ready within timeout"
        exit 1
    fi
    
    log "Orchestrator is ready - proceeding with worker initialization"
}

# Initialize Oakestra worker node
init_oakestra_worker() {
    log "Starting Oakestra worker node initialization..."

    # Start NodeEngine with orchestrator IP address (-d runs it as systemd daemon)
    log "Starting NodeEngine daemon with orchestrator at $ORCHESTRATOR_IP..."

    sudo NodeEngine -a "$ORCHESTRATOR_IP" -d

    # Wait a moment for systemd service to start
    sleep 2

    # Detect the worker's private IP from Hetzner private network (10.0.0.x)
    # Try both eth0 and enp7s0 (Hetzner uses enp7s0 for private network)
    PRIVATE_IP=$(ip addr show enp7s0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '^10\.0\.' || \
                 ip addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '^10\.0\.')

    if [ -z "$PRIVATE_IP" ]; then
        log "WARNING: Could not detect private IP on 10.0.0.0/16 network, using primary IP"
        PRIVATE_IP=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+')
    fi

    log "Detected worker private IP: $PRIVATE_IP"

    # Fix NetManager configuration to use correct orchestrator IP and node address
    log "Configuring NetManager with orchestrator IP and node address..."
    if [ -f /etc/netmanager/netcfg.json ]; then
        # Update ClusterUrl to point to orchestrator private IP
        # Update NodePublicAddress to use worker's private IP
        jq --arg cluster_ip "$ORCHESTRATOR_IP" \
           --arg node_ip "$PRIVATE_IP" \
           '.ClusterUrl = $cluster_ip | .NodePublicAddress = $node_ip' \
           /etc/netmanager/netcfg.json > /tmp/netcfg.json.tmp
        mv /tmp/netcfg.json.tmp /etc/netmanager/netcfg.json

        log "NetManager config updated:"
        log "  ClusterUrl=$ORCHESTRATOR_IP"
        log "  NodePublicAddress=$PRIVATE_IP"
    else
        log "WARNING: /etc/netmanager/netcfg.json not found"
    fi

    # Fix NodeEngine configuration to use correct node IP
    log "Configuring NodeEngine with node IP address..."
    if [ -f /etc/oakestra/conf.json ]; then
        # Add node_ip field to NodeEngine config if it doesn't exist
        jq --arg node_ip "$PRIVATE_IP" \
           '.node_ip = $node_ip' \
           /etc/oakestra/conf.json > /tmp/conf.json.tmp
        mv /tmp/conf.json.tmp /etc/oakestra/conf.json

        log "NodeEngine config updated with node_ip=$PRIVATE_IP"
    else
        log "WARNING: /etc/oakestra/conf.json not found"
    fi

    # Restart services to apply new configuration
    log "Restarting NetManager and NodeEngine services..."
    NodeEngine stop
    NodeEngine -a "$ORCHESTRATOR_IP" -d
    sleep 3

    # Verify nodeengined daemon is running (systemd service)
    if pgrep -f "nodeengined" >/dev/null 2>&1; then
        NODEENGINE_PID=$(pgrep -f "nodeengined")
        log "NodeEngine daemon is running (PID: $NODEENGINE_PID)"
    else
        log "WARNING: nodeengined process not found, checking systemd service..."
        if systemctl is-active --quiet nodeengine.service; then
            log "NodeEngine service is active"
        else
            log "ERROR: NodeEngine daemon failed to start"
            exit 1
        fi
    fi

    log "Worker initialization complete"
}

# Get worker metadata from Terraform labels
get_worker_info() {
    # Try to get worker ID from instance metadata or use hostname
    WORKER_ID=$(hostname | sed 's/.*-//')
    log "Worker ID: $WORKER_ID"
    
    # Get private IP
    WORKER_IP=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+')
    log "Worker IP: $WORKER_IP"
}

main() {
    log "=== Oakestra Worker Initialization Starting ==="

    get_worker_info
    wait_for_system
    init_tailscale
    wait_for_orchestrator
    init_oakestra_worker

    log "=== Worker node ready and connected ==="
}

main