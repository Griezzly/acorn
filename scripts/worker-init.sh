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
    
    # Start NodeEngine with orchestrator IP address
    log "Starting NodeEngine with orchestrator at $ORCHESTRATOR_IP..."
    
    # Start NodeEngine as a background service
    nohup sudo NodeEngine -a "$ORCHESTRATOR_IP" -d > /var/log/nodeengine.log 2>&1 &
    NODEENGINE_PID=$!
    
    log "NodeEngine started with PID: $NODEENGINE_PID"
    
    # Wait for NodeEngine to be ready
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check if NodeEngine process is still running
        if kill -0 "$NODEENGINE_PID" 2>/dev/null; then
            log "NodeEngine is running (PID: $NODEENGINE_PID)"
            break
        else
            log "NodeEngine process died, checking if it restarted..."
            # Check if NodeEngine is running under a different PID
            if pgrep -f "NodeEngine" >/dev/null 2>&1; then
                NEW_PID=$(pgrep -f "NodeEngine")
                log "NodeEngine is running with new PID: $NEW_PID"
                break
            fi
        fi
        
        log "Attempt $attempt/$max_attempts: Waiting for NodeEngine to be ready..."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log "WARNING: NodeEngine health check timed out"
        log "NodeEngine log output:"
        tail -20 /var/log/nodeengine.log | while read line; do
            log "NodeEngine: $line"
        done
    else
        log "NodeEngine is running successfully"
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