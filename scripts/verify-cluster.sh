#!/bin/bash

# Oakestra Cluster Verification Script
# Verifies that the deployed cluster is fully operational

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in terraform directory or need to change to it
if [ ! -f "terraform.tfvars" ] && [ -d "$TERRAFORM_DIR" ]; then
    cd "$TERRAFORM_DIR"
fi

# Get orchestrator IP from Terraform output
log_info "Getting orchestrator IP from Terraform..."
ORCHESTRATOR_IP=$(terraform output -raw orchestrator_public_ipv4 2>/dev/null)

if [ -z "$ORCHESTRATOR_IP" ]; then
    log_error "Failed to get orchestrator IP from Terraform"
    log_error "Make sure you're in the terraform directory and have run 'terraform apply'"
    exit 1
fi

log_info "Orchestrator IP: $ORCHESTRATOR_IP"

# Get expected worker count
WORKER_COUNT=$(terraform output -json workers_info 2>/dev/null | jq -r 'length')
if [ -z "$WORKER_COUNT" ] || [ "$WORKER_COUNT" = "null" ]; then
    log_warn "Could not determine worker count from Terraform, defaulting to 1"
    WORKER_COUNT=1
fi

log_info "Expected worker count: $WORKER_COUNT"

# Check API docs endpoint
log_info "Checking Oakestra API availability..."
if curl -f --connect-timeout 10 "http://${ORCHESTRATOR_IP}:10000/api/docs" >/dev/null 2>&1; then
    log_info "✓ API docs endpoint is accessible"
else
    log_error "✗ API docs endpoint is not accessible at http://${ORCHESTRATOR_IP}:10000/api/docs"
    log_error "Orchestrator may still be initializing. Check logs with:"
    log_error "  ssh root@${ORCHESTRATOR_IP} 'tail -f /var/log/oakestra-init.log'"
    exit 1
fi

# Login and get auth token
log_info "Authenticating with Oakestra API..."
TOKEN=$(curl -s -X POST "http://${ORCHESTRATOR_IP}:10000/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"Admin","password":"Admin"}' | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    log_error "✗ Failed to authenticate with Oakestra API"
    exit 1
fi

log_info "✓ Successfully authenticated"

# Get cluster information
log_info "Fetching cluster information..."
CLUSTER_INFO=$(curl -s -X GET "http://${ORCHESTRATOR_IP}:10000/api/clusters/" \
    -H "Authorization: Bearer $TOKEN")

if [ -z "$CLUSTER_INFO" ]; then
    log_error "✗ Failed to fetch cluster information"
    exit 1
fi

# Parse cluster details
CLUSTER_NAME=$(echo "$CLUSTER_INFO" | jq -r '.[0].cluster_name')
ACTIVE_NODES=$(echo "$CLUSTER_INFO" | jq -r '.[0].active_nodes')
TOTAL_CPU=$(echo "$CLUSTER_INFO" | jq -r '.[0].total_cpu_cores')
TOTAL_MEMORY=$(echo "$CLUSTER_INFO" | jq -r '.[0].memory_in_mb')

log_info "Cluster Name: $CLUSTER_NAME"
log_info "Active Nodes: $ACTIVE_NODES"
log_info "Total CPU Cores: $TOTAL_CPU"
log_info "Total Memory: ${TOTAL_MEMORY} MB"

# Verify active nodes match expected worker count
echo ""
if [ "$ACTIVE_NODES" -eq "$WORKER_COUNT" ]; then
    log_info "✓ ${GREEN}Cluster verification PASSED${NC}"
    log_info "✓ All $WORKER_COUNT worker node(s) successfully connected"
    echo ""
    echo "Cluster Details:"
    echo "$CLUSTER_INFO" | jq '.[0] | {cluster_name, active_nodes, total_cpu_cores, memory_in_mb, cluster_location}'
    exit 0
else
    log_error "✗ ${RED}Cluster verification FAILED${NC}"
    log_error "Expected $WORKER_COUNT worker(s), but only $ACTIVE_NODES are active"
    echo ""

    if [ "$ACTIVE_NODES" -eq 0 ]; then
        log_warn "No workers are connected. Possible issues:"
        log_warn "  1. Workers are still initializing (wait 2-3 minutes after deployment)"
        log_warn "  2. Worker initialization failed"
        log_warn ""
        log_warn "Check worker logs:"

        # Get worker IPs
        WORKER_IPS=$(terraform output -json worker_public_ipv4s 2>/dev/null | jq -r '.[]')
        for WORKER_IP in $WORKER_IPS; do
            log_warn "  ssh root@${WORKER_IP} 'tail -50 /var/log/oakestra-worker-init.log'"
        done
    else
        log_warn "Some workers connected, but not all. Check individual worker logs."
    fi

    exit 1
fi