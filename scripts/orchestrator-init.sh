#!/bin/bash

# Oakestra Orchestrator Initialization Script
# This script ensures the root orchestrator is properly initialized before workers can connect

set -e

LOG_FILE="/var/log/oakestra-init.log"
READY_FLAG="/tmp/oakestra-ready"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>&1
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
        tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="acorn-orchestrator" --accept-routes

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

# Setup Oakestra environment variables
setup_oakestra_environment() {
    log "Setting up Oakestra environment variables..."
    
    # Set default branch
    export OAKESTRA_BRANCH="${OAKESTRA_BRANCH:-main}"
    log "OAKESTRA_BRANCH: $OAKESTRA_BRANCH"
    
    # Get the system's private IP address (from private subnet)
    SYSTEM_MANAGER_URL="10.0.1.10"  # Fixed private IP from Terraform config
    export SYSTEM_MANAGER_URL
    log "SYSTEM_MANAGER_URL: $SYSTEM_MANAGER_URL"
    
    # Try to get public IP for location detection
    PUBLIC_IP=""
    if command -v curl >/dev/null 2>&1; then
        PUBLIC_IP=$(curl -s --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null || echo "")
    fi
    
    if [ -z "$PUBLIC_IP" ]; then
        log "Could not detect public IP, using default location"
        CLUSTER_LOCATION="${CLUSTER_LOCATION:-0.0,0.0,100}"
    else
        log "Public IP detected: $PUBLIC_IP"
        # Try to get location from IP
        if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            LOCATION_DATA=$(curl -s --connect-timeout 10 "https://ipinfo.io/$PUBLIC_IP/json" 2>/dev/null || echo "")
            if [ -n "$LOCATION_DATA" ]; then
                LAT=$(echo "$LOCATION_DATA" | jq -r '.loc // empty' | cut -d',' -f1 2>/dev/null || echo "")
                LON=$(echo "$LOCATION_DATA" | jq -r '.loc // empty' | cut -d',' -f2 2>/dev/null || echo "")
                if [ -n "$LAT" ] && [ -n "$LON" ]; then
                    CLUSTER_LOCATION="${CLUSTER_LOCATION:-$LAT,$LON,100}"
                    log "Location detected from IP: $LAT,$LON"
                else
                    CLUSTER_LOCATION="${CLUSTER_LOCATION:-0.0,0.0,100}"
                    log "Could not parse location data, using default"
                fi
            else
                CLUSTER_LOCATION="${CLUSTER_LOCATION:-0.0,0.0,100}"
                log "Could not get location data, using default"
            fi
        else
            CLUSTER_LOCATION="${CLUSTER_LOCATION:-0.0,0.0,100}"
            log "jq not available, using default location"
        fi
    fi
    
    export CLUSTER_LOCATION
    log "CLUSTER_LOCATION: $CLUSTER_LOCATION"
    
    # Set cluster name
    export CLUSTER_NAME="${CLUSTER_NAME:-acorn-benchmark-cluster}"
    log "CLUSTER_NAME: $CLUSTER_NAME"
    
    # Set any override files if needed
    export OVERRIDE_FILES="${OVERRIDE_FILES:-}"
    if [ -n "$OVERRIDE_FILES" ]; then
        log "OVERRIDE_FILES: $OVERRIDE_FILES"
    fi
    
    log "Environment variables configured successfully"
    
    # Create .env file for docker-compose
    create_env_file
}

# Create .env file for docker-compose
create_env_file() {
    log "Creating .env file for docker-compose..."
    
    ENV_FILE=".env"
    cat > "$ENV_FILE" << EOF
# Oakestra Environment Variables
OAKESTRA_BRANCH=$OAKESTRA_BRANCH
SYSTEM_MANAGER_URL=$SYSTEM_MANAGER_URL
CLUSTER_LOCATION=$CLUSTER_LOCATION
CLUSTER_NAME=$CLUSTER_NAME
EOF
    
    if [ -n "$OVERRIDE_FILES" ]; then
        echo "OVERRIDE_FILES=$OVERRIDE_FILES" >> "$ENV_FILE"
    fi
    
    log ".env file created with Oakestra configuration"
    log "Contents:"
    while IFS= read -r line; do
        log "  $line"
    done < "$ENV_FILE"
}

# Initialize Oakestra root orchestrator
init_oakestra_orchestrator() {
    log "Starting Oakestra root orchestrator initialization..."

    # Set the Oakestra directory (from snapshot)
    OAKESTRA_DIR="/home/carsten/oakestra"

    if [ ! -d "$OAKESTRA_DIR" ]; then
        log "ERROR: Oakestra directory not found at $OAKESTRA_DIR"
        exit 1
    fi

    cd "$OAKESTRA_DIR" || exit 1
    log "Changed to Oakestra directory: $(pwd)"

    # Check if docker and docker-compose are available
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR: Docker not found"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log "ERROR: Docker Compose v2 not found"
        exit 1
    fi

    log "Docker and Docker Compose are available"

    # Setup Oakestra environment variables
    setup_oakestra_environment

    # Stop any existing Oakestra services (in case they're partially running)
    log "Stopping any existing Oakestra services..."
    docker compose -f 1-DOC.yaml down 2>/dev/null || true

    # Use the stable docker compose file with pinned versions
    STABLE_COMPOSE_FILE="oakestra-stable.yaml"

    if [ ! -f "$STABLE_COMPOSE_FILE" ]; then
        log "WARNING: Stable compose file not found at $STABLE_COMPOSE_FILE, checking for 1-DOC.yaml fallback..."
        if [ -f "1-DOC.yaml" ]; then
            STABLE_COMPOSE_FILE="1-DOC.yaml"
        elif [ -f "1-DOC.yml" ]; then
            STABLE_COMPOSE_FILE="1-DOC.yml"
        else
            log "ERROR: No compose file found"
            exit 1
        fi
    fi

    # Start the 1-DOC setup (root orchestrator + single cluster)
    log "Starting Oakestra 1-DOC setup with stable versions from $STABLE_COMPOSE_FILE..."

    docker compose -f "$STABLE_COMPOSE_FILE" up -d
    COMPOSE_EXIT_CODE=$?

    if [ $COMPOSE_EXIT_CODE -ne 0 ]; then
        log "ERROR: Docker compose failed to start services (exit code: $COMPOSE_EXIT_CODE)"
        diagnose_container_failures
        exit 1
    fi

    log "Docker compose services started successfully"
    
    # Give containers a moment to initialize
    sleep 10
    
    # Check container status immediately after startup
    check_container_health
    
    # Wait for key services to be ready
    wait_for_services
    
    # Create ready flag file
    touch "$READY_FLAG"
    log "Orchestrator initialization complete - ready flag created"
}

# Wait for essential Oakestra services to be ready
wait_for_services() {
    log "Waiting for Oakestra services to be ready..."
    
    # Wait for System Manager API (port 10000)
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt/$max_attempts: Checking System Manager API..."
        
        if curl -f --connect-timeout 5 "http://localhost:10000/api/docs" >/dev/null 2>&1; then
            log "System Manager API is ready"
            break
        fi
        
        # Fallback: check if port is listening
        if netstat -ln | grep -q ":10000.*LISTEN" 2>/dev/null; then
            log "System Manager port 10000 is listening"
            break
        fi
        
        log "System Manager not ready yet, waiting..."
        sleep 10
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log "WARNING: System Manager API health check timed out"
        log "Checking docker container status..."
        docker compose -f 1-DOC.yaml ps || docker compose -f 1-DOC.yml ps || true
        log "Checking docker logs for system manager..."
        docker compose -f 1-DOC.yaml logs system_manager 2>/dev/null | tail -10 || \
        docker compose -f 1-DOC.yml logs system_manager 2>/dev/null | tail -10 || true
    else
        log "Essential services are ready"
    fi
    
    # Additional service checks
    check_service_ports
}

# Diagnose container failures
diagnose_container_failures() {
    log "=== DIAGNOSING CONTAINER FAILURES ==="
    
    log "Current container status:"
    docker compose -f 1-DOC.yaml ps || docker compose -f 1-DOC.yml ps || true
    
    log "All containers (including stopped):"
    docker ps -a | head -20 | while IFS= read -r line; do log "  $line"; done
    
    log "Docker daemon status:"
    systemctl is-active docker || true
    
    log "Available disk space:"
    df -h | head -5 | while IFS= read -r line; do log "  $line"; done
    
    log "Memory usage:"
    free -h | while IFS= read -r line; do log "  $line"; done
    
    log "Recent docker events:"
    docker events --since 5m --until now | tail -10 | while IFS= read -r line; do log "  $line"; done || true
}

# Check container health after startup
check_container_health() {
    log "=== CHECKING CONTAINER HEALTH ==="

    # Use the stable compose file or fallback
    local compose_file="${STABLE_COMPOSE_FILE:-oakestra-stable.yaml}"

    log "Container status (using $compose_file):"
    docker compose -f "$compose_file" ps

    # Check for failed/exited containers
    FAILED_CONTAINERS=$(docker compose -f "$compose_file" ps --format "table {{.Name}}\t{{.State}}" | grep -v "running" | grep -v "NAME" | cut -f1 || true)

    if [ -n "$FAILED_CONTAINERS" ]; then
        log "Found failed/stopped containers, checking logs:"
        echo "$FAILED_CONTAINERS" | while IFS= read -r container; do
            if [ -n "$container" ]; then
                log "=== Logs for $container ==="
                docker compose -f "$compose_file" logs "$container" | tail -20 | while IFS= read -r line; do log "  $line"; done
            fi
        done
    else
        log "All containers appear to be running"
    fi
}

# Check that essential service ports are accessible
check_service_ports() {
    log "Checking essential service ports..."
    
    # Key ports for Oakestra
    local ports="80 10000 10007 10008"
    local ready_ports=0
    
    for port in $ports; do
        if netstat -ln | grep -q ":$port.*LISTEN" 2>/dev/null; then
            log "Port $port is listening"
            ready_ports=$((ready_ports + 1))
        else
            log "WARNING: Port $port is not listening"
        fi
    done
    
    log "Ready ports: $ready_ports/$(echo $ports | wc -w)"
    
    if [ $ready_ports -ge 2 ]; then
        log "Sufficient services are running"
        return 0
    else
        log "WARNING: Limited services are ready"
        return 1
    fi
}

# Expose readiness via HTTP endpoint for workers to check
start_readiness_server() {
    log "Starting readiness check server on port 9999..."
    
    # Simple HTTP server that responds 200 when orchestrator is ready
    while true; do
        if [ -f "$READY_FLAG" ]; then
            echo -e "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready" | nc -l -p 9999 -q 1
        else
            echo -e "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 11\r\n\r\nnot ready" | nc -l -p 9999 -q 1
        fi
    done &
    
    log "Readiness server started"
}

main() {
    log "=== Oakestra Orchestrator Initialization Starting ==="

    wait_for_system
    init_tailscale
    start_readiness_server
    init_oakestra_orchestrator

    log "=== Orchestrator ready for worker connections ==="

    # Keep the script running to maintain the readiness server
    wait
}

# Run main function directly - systemd will manage the process
main