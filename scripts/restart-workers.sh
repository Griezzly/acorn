#!/bin/bash

# Script to restart NodeEngine on all worker nodes
# Usage: ./scripts/restart-workers.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Restarting NodeEngine on Worker Nodes ===${NC}\n"

# Check if terraform directory exists
if [ ! -d "$TERRAFORM_DIR" ]; then
    echo -e "${RED}Error: Terraform directory not found at $TERRAFORM_DIR${NC}"
    exit 1
fi

# Get worker IPs from terraform output
cd "$TERRAFORM_DIR"
echo -e "${YELLOW}Fetching worker IPs from Terraform...${NC}"

WORKER_IPS=$(terraform output -json worker_public_ipv4s 2>/dev/null | jq -r '.[]')

if [ -z "$WORKER_IPS" ]; then
    echo -e "${RED}Error: No worker IPs found in Terraform output${NC}"
    exit 1
fi

echo -e "${GREEN}Found worker nodes:${NC}"
echo "$WORKER_IPS" | nl

ORCHESTRATOR_IP="10.0.1.10"

# Restart NodeEngine on each worker
for WORKER_IP in $WORKER_IPS; do
    echo -e "\n${YELLOW}Restarting NodeEngine on $WORKER_IP...${NC}"

    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"$WORKER_IP" \
        "NodeEngine stop && NodeEngine -a $ORCHESTRATOR_IP -d" 2>&1; then
        echo -e "${GREEN}✓ Successfully restarted NodeEngine on $WORKER_IP${NC}"
    else
        echo -e "${RED}✗ Failed to restart NodeEngine on $WORKER_IP${NC}"
    fi
done

echo -e "\n${GREEN}=== NodeEngine restart complete ===${NC}"