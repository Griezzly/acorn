#!/bin/bash
set -e

# Script to clear SSH known_hosts entries for all deployed Hetzner nodes
# This is useful when redeploying infrastructure with new snapshots

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Load IPs from Terraform
cd "$PROJECT_DIR/terraform"

if ! terraform output -json > /tmp/terraform_output.json 2>/dev/null; then
    log_error "Failed to load Terraform outputs. Make sure infrastructure is deployed."
    exit 1
fi

# Get orchestrator IP
ORCHESTRATOR_IP=$(jq -r '.orchestrator_public_ipv4.value' /tmp/terraform_output.json)

# Get worker IPs into array (compatible with older bash)
WORKER_IPS=()
while IFS= read -r ip; do
    WORKER_IPS+=("$ip")
done < <(jq -r '.worker_public_ipv4s.value[]' /tmp/terraform_output.json)

log_info "Found infrastructure:"
log_info "  Orchestrator: $ORCHESTRATOR_IP"
for i in "${!WORKER_IPS[@]}"; do
    log_info "  Worker $((i+1)): ${WORKER_IPS[$i]}"
done

echo ""
log_info "Clearing SSH known_hosts entries..."

# Clear orchestrator
if ssh-keygen -R "$ORCHESTRATOR_IP" 2>&1 | grep -q "found"; then
    log_success "Removed orchestrator ($ORCHESTRATOR_IP) from known_hosts"
else
    log_info "Orchestrator ($ORCHESTRATOR_IP) not found in known_hosts"
fi

# Clear workers
for i in "${!WORKER_IPS[@]}"; do
    if ssh-keygen -R "${WORKER_IPS[$i]}" 2>&1 | grep -q "found"; then
        log_success "Removed worker-$((i+1)) (${WORKER_IPS[$i]}) from known_hosts"
    else
        log_info "Worker-$((i+1)) (${WORKER_IPS[$i]}) not found in known_hosts"
    fi
done

echo ""
log_success "Done! SSH known_hosts entries cleared for all nodes."
log_info "On next SSH connection, you'll be prompted to accept new host keys."

# Cleanup
rm -f /tmp/terraform_output.json