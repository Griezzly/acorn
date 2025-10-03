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
    wait_for_orchestrator
    init_oakestra_worker
    
    log "=== Worker node ready and connected ==="
}

main