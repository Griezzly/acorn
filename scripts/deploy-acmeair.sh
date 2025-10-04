#!/bin/bash

# Acme Air Deployment Automation for Oakestra
# Deploys SLA and creates service instances in dependency order

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
SLA_FILE="${SCRIPT_DIR}/../service-slas/acmeair.json"
CONFIG_FILE="${SCRIPT_DIR}/../service-slas/deployment-config.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Check prerequisites
for cmd in jq curl yq; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd is required but not installed"
        exit 1
    fi
done

if [ ! -f "$SLA_FILE" ]; then
    log_error "SLA file not found: $SLA_FILE"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

# Get orchestrator IP
log_step "Getting orchestrator IP..."

# Try Terraform first
if [ -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
    cd "$TERRAFORM_DIR"
    ORCH_IP=$(terraform output -raw orchestrator_public_ipv4 2>/dev/null)
    if [ -n "$ORCH_IP" ] && [ "$ORCH_IP" != "null" ]; then
        log_info "Got IP from Terraform: $ORCH_IP"
    fi
fi

# Fall back to environment variable
if [ -z "${ORCH_IP:-}" ] || [ "$ORCH_IP" = "null" ]; then
    ORCH_IP="${ORCHESTRATOR_IP:-}"
fi

# Last resort: config file
if [ -z "${ORCH_IP:-}" ] || [ "$ORCH_IP" = "null" ]; then
    ORCH_IP=$(yq e '.orchestrator_ip' "$CONFIG_FILE" 2>/dev/null || echo "")
fi

if [ -z "$ORCH_IP" ] || [ "$ORCH_IP" = "null" ] || [ "$ORCH_IP" = '${ORCHESTRATOR_IP}' ]; then
    log_error "Cannot determine orchestrator IP"
    log_error "Options:"
    log_error "  1. Run 'terraform apply' in terraform/ directory"
    log_error "  2. Set ORCHESTRATOR_IP environment variable"
    log_error "  3. Update orchestrator_ip in deployment-config.yaml"
    exit 1
fi

log_info "Orchestrator: $ORCH_IP"
BASE_URL="http://${ORCH_IP}:10000"

# Wait for API
log_step "Waiting for Oakestra API..."
MAX_WAIT=120
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if curl -f --connect-timeout 5 "${BASE_URL}/api/docs" >/dev/null 2>&1; then
        log_info "✓ API ready"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    log_error "Timeout waiting for API"
    exit 1
fi

# Authenticate
log_step "Authenticating..."
TOKEN=$(curl -s -X POST "${BASE_URL}/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"Admin","password":"Admin"}' | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    log_error "Authentication failed"
    exit 1
fi

log_info "✓ Authenticated"

# Check for existing app
log_step "Checking existing deployments..."
EXISTING=$(curl -s -X GET "${BASE_URL}/api/applications/" \
    -H "Authorization: Bearer $TOKEN")

APP_ID=$(echo "$EXISTING" | jq -r 'try . catch "[]"' | jq -r '.[] | select(.application_name == "acmeair") | .applicationID' 2>/dev/null || echo "")

if [ -n "$APP_ID" ] && [ "$APP_ID" != "null" ]; then
    log_warn "Application exists (ID: $APP_ID)"

    if [ "${FORCE_REDEPLOY:-}" != "true" ]; then
        read -p "Delete and redeploy? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    log_info "Deleting application..."
    curl -s -X DELETE "${BASE_URL}/api/application/${APP_ID}" \
        -H "Authorization: Bearer $TOKEN" >/dev/null
    sleep 10
    log_info "✓ Deleted"
fi

# Deploy SLA
log_step "Deploying SLA to Oakestra..."
DEPLOY_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/application/" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d @"$SLA_FILE")

APP_INFO=$(echo "$DEPLOY_RESPONSE" | jq -r . 2>/dev/null | jq .[0] 2>/dev/null)

APP_ID=$(echo "$APP_INFO" | jq -r '.applicationID')
APP_NAME=$(echo "$APP_INFO" | jq -r '.application_name')

if [ -z "$APP_ID" ] || [ "$APP_ID" = "null" ]; then
    log_error "SLA deployment failed"
    log_error "Response: $DEPLOY_RESPONSE"
    exit 1
fi

log_info "✓ SLA deployed"
log_info "  Application: $APP_NAME (ID: $APP_ID)"

# Get service IDs from deployment
declare -A SERVICE_IDS
MICROSERVICES=$(echo "$APP_INFO" | jq -r '.microservices[]')

for SVC_ID in $MICROSERVICES; do
    SVC_DETAIL=$(curl -s -X GET "${BASE_URL}/api/service/${SVC_ID}" \
        -H "Authorization: Bearer $TOKEN")
    SVC_NAME=$(echo "$SVC_DETAIL" | jq -r '.microservice_name')
    SERVICE_IDS[$SVC_NAME]=$SVC_ID
    log_info "  Service: $SVC_NAME -> $SVC_ID"
done

# Deploy instances in order
DEPLOYMENT_ORDER=$(yq e '.deployment_order' "$CONFIG_FILE" -o=json)
NUM_SERVICES=$(echo "$DEPLOYMENT_ORDER" | jq 'length')

echo ""
log_step "Deploying service instances..."

for i in $(seq 0 $((NUM_SERVICES - 1))); do
    SVC_NAME=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].service")
    INSTANCES=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].instances")
    WAIT_TIME=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].wait_time")

    SVC_ID="${SERVICE_IDS[$SVC_NAME]}"

    if [ -z "$SVC_ID" ] || [ "$SVC_ID" = "null" ]; then
        log_error "Service ID not found for: $SVC_NAME"
        exit 1
    fi

    log_info "Deploying $SVC_NAME (${INSTANCES} instance(s))..."

    for j in $(seq 1 $INSTANCES); do
        INSTANCE_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/service/${SVC_ID}/instance" \
            -H "Authorization: Bearer $TOKEN")

        if echo "$INSTANCE_RESPONSE" | jq -e . >/dev/null 2>&1; then
            log_info "  ✓ Instance $j created"
        else
            log_error "  ✗ Failed to create instance $j"
            log_error "  Response: $INSTANCE_RESPONSE"
        fi
    done

    if [ "$i" -lt $((NUM_SERVICES - 1)) ]; then
        log_info "  Waiting ${WAIT_TIME}s for $SVC_NAME to stabilize..."
        sleep "$WAIT_TIME"
    fi
done

# Post-deployment tasks
INIT_DB=$(yq e '.post_deployment.initialize_db' "$CONFIG_FILE")

if [ "$INIT_DB" = "true" ]; then
    echo ""
    log_step "Running post-deployment tasks..."

    DB_ENDPOINT=$(yq e '.post_deployment.db_endpoint' "$CONFIG_FILE")

    log_info "Initializing database..."
    sleep 10

    DB_RESPONSE=$(curl -s -X GET "$DB_ENDPOINT" 2>/dev/null || echo "")
    log_info "✓ Database initialization triggered"

    # Validation
    VAL_ENDPOINT=$(yq e '.post_deployment.validation_endpoint' "$CONFIG_FILE")
    VAL_LOGIN=$(yq e '.post_deployment.validation_credentials.login' "$CONFIG_FILE")
    VAL_PASS=$(yq e '.post_deployment.validation_credentials.password' "$CONFIG_FILE")

    log_info "Validating deployment..."
    sleep 5

    VAL_RESPONSE=$(curl -s -X POST "$VAL_ENDPOINT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "login=${VAL_LOGIN}&password=${VAL_PASS}" 2>/dev/null || echo "{}")

    if echo "$VAL_RESPONSE" | jq -e '.sessionid' >/dev/null 2>&1; then
        log_info "✓ Validation successful"
    else
        log_warn "Validation failed - may need more time"
    fi
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Deployment Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Application ID: $APP_ID"
log_info "Services deployed:"

for SVC_NAME in "${!SERVICE_IDS[@]}"; do
    log_info "  - $SVC_NAME: ${SERVICE_IDS[$SVC_NAME]}"
done

echo ""
log_info "Access: http://10.30.10.2:9080"
log_info "Credentials: uid0@email.com / password"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"