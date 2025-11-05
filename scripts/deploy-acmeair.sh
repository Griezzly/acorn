#!/opt/homebrew/bin/bash

# Acme Air Deployment Automation for Oakestra
# Deploys SLA and creates service instances in dependency order

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
SLA_DIR="${SCRIPT_DIR}/../service-slas"
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

# Readiness check function
check_readiness() {
    local service_name=$1
    local check_type=$2
    local timeout=$3
    local retries=$4
    local retry_delay=$5

    if [ "$check_type" = "tcp" ]; then
        local host=$6
        local port=$7

        log_info "  Checking TCP connectivity to ${host}:${port}..."

        for attempt in $(seq 1 "$retries"); do
            if timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
                log_info "  ✓ $service_name is ready (attempt $attempt/$retries)"
                return 0
            fi

            if [ "$attempt" -lt "$retries" ]; then
                log_warn "  Attempt $attempt/$retries failed, retrying in ${retry_delay}s..."
                sleep "$retry_delay"
            fi
        done

        log_error "  ✗ $service_name failed readiness check after $retries attempts"
        return 1

    elif [ "$check_type" = "http" ]; then
        local endpoint=$6
        local expected_statuses=$7

        log_info "  Checking HTTP endpoint: $endpoint..."

        for attempt in $(seq 1 "$retries"); do
            http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" "$endpoint" 2>/dev/null || echo "000")

            # Check if status code matches any expected status
            for status in $expected_statuses; do
                if [ "$http_code" = "$status" ]; then
                    log_info "  ✓ $service_name is ready (HTTP $http_code, attempt $attempt/$retries)"
                    return 0
                fi
            done

            if [ "$attempt" -lt "$retries" ]; then
                log_warn "  Attempt $attempt/$retries failed (HTTP $http_code), retrying in ${retry_delay}s..."
                sleep "$retry_delay"
            fi
        done

        log_error "  ✗ $service_name failed readiness check after $retries attempts (last HTTP code: $http_code)"
        return 1
    fi
}

# Check prerequisites
for cmd in jq curl yq; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd is required but not installed"
        exit 1
    fi
done

if [ ! -d "$SLA_DIR" ]; then
    log_error "SLA directory not found: $SLA_DIR"
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

# Get SLA files to deploy
SLA_FILES=$(yq e '.sla_files[]' "$CONFIG_FILE")

# Check for existing apps and optionally delete
log_step "Checking existing deployments..."
EXISTING=$(curl -s -X GET "${BASE_URL}/api/applications/" \
    -H "Authorization: Bearer $TOKEN")

SHOULD_DELETE=false
for SLA_FILE_NAME in $SLA_FILES; do
    SLA_FILE="${SLA_DIR}/${SLA_FILE_NAME}"

    if [ ! -f "$SLA_FILE" ]; then
        log_error "SLA file not found: $SLA_FILE"
        exit 1
    fi

    APP_NAME=$(jq -r '.applications[0].application_name' "$SLA_FILE")
    APP_ID=$(echo "$EXISTING" | sed 's/^"\(.*\)"$/\1/' | sed 's/\\"/"/g' | jq -r ".[] | select(.application_name == \"$APP_NAME\") | .applicationID" 2>/dev/null || echo "")

    if [ -n "$APP_ID" ] && [ "$APP_ID" != "null" ]; then
        log_warn "Application $APP_NAME exists (ID: $APP_ID)"
        SHOULD_DELETE=true
    fi
done

if [ "$SHOULD_DELETE" = "true" ]; then
    if [ "${FORCE_REDEPLOY:-}" != "true" ]; then
        read -p "Delete existing applications and redeploy? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    # Delete existing applications
    for SLA_FILE_NAME in $SLA_FILES; do
        SLA_FILE="${SLA_DIR}/${SLA_FILE_NAME}"
        APP_NAME=$(jq -r '.applications[0].application_name' "$SLA_FILE")
        APP_ID=$(echo "$EXISTING" | sed 's/^"\(.*\)"$/\1/' | sed 's/\\"/"/g' | jq -r ".[] | select(.application_name == \"$APP_NAME\") | .applicationID" 2>/dev/null || echo "")

        if [ -n "$APP_ID" ] && [ "$APP_ID" != "null" ]; then
            log_info "Deleting $APP_NAME..."
            curl -s -X DELETE "${BASE_URL}/api/application/${APP_ID}" \
                -H "Authorization: Bearer $TOKEN" >/dev/null
        fi
    done
    sleep 10
    log_info "✓ Deleted existing applications"
fi

# Deploy all SLAs
log_step "Deploying SLAs to Oakestra..."
declare -A SERVICE_IDS

for SLA_FILE_NAME in $SLA_FILES; do
    SLA_FILE="${SLA_DIR}/${SLA_FILE_NAME}"

    log_info "Deploying $SLA_FILE_NAME..."
    DEPLOY_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/application/" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d @"$SLA_FILE")

    # Debug: Show raw response
    log_info "  Raw API response length: ${#DEPLOY_RESPONSE} chars"
    if [ ${#DEPLOY_RESPONSE} -lt 100 ]; then
        log_warn "  Short response, showing full content: $DEPLOY_RESPONSE"
    fi

    # Try to parse response - handle both array and object responses
    APP_INFO=$(echo "$DEPLOY_RESPONSE" | sed 's/^"\(.*\)"$/\1/' | sed 's/\\"/"/g' | jq '.[0]' 2>/dev/null)

    # If array parsing failed, try as direct object
    if [ -z "$APP_INFO" ] || [ "$APP_INFO" = "null" ]; then
        log_warn "  Array parsing failed, trying as object..."
        APP_INFO=$(echo "$DEPLOY_RESPONSE" | sed 's/^"\(.*\)"$/\1/' | sed 's/\\"/"/g' | jq '.' 2>/dev/null)
    fi

    APP_ID=$(echo "$APP_INFO" | jq -r '.applicationID' 2>/dev/null)
    APP_NAME=$(echo "$APP_INFO" | jq -r '.application_name' 2>/dev/null)

    if [ -z "$APP_ID" ] || [ "$APP_ID" = "null" ]; then
        log_error "SLA deployment failed for $SLA_FILE_NAME"
        log_error "Raw response (first 500 chars): ${DEPLOY_RESPONSE:0:500}"
        log_error "Parsed APP_INFO: $APP_INFO"
        exit 1
    fi

    log_info "  ✓ Application: $APP_NAME (ID: $APP_ID)"

    # Get service IDs from this deployment
    MICROSERVICES=$(echo "$APP_INFO" | jq -r '.microservices[]' 2>/dev/null)

    if [ -z "$MICROSERVICES" ]; then
        log_warn "  No microservices found in response"
        log_warn "  APP_INFO microservices field: $(echo "$APP_INFO" | jq -r '.microservices' 2>/dev/null)"
    fi

    for SVC_ID in $MICROSERVICES; do
        log_info "    Fetching details for service ID: $SVC_ID"
        SVC_DETAIL=$(curl -s -X GET "${BASE_URL}/api/service/${SVC_ID}" \
            -H "Authorization: Bearer $TOKEN")

        # Debug: Show response length and first 100 chars
        log_info "    Service detail response length: ${#SVC_DETAIL} chars"

        SVC_NAME=$(echo "$SVC_DETAIL" | sed 's/^"\(.*\)"$/\1/' | sed 's/\\"/"/g' | jq -r '.microservice_name' 2>/dev/null)

        if [ -z "$SVC_NAME" ] || [ "$SVC_NAME" = "null" ]; then
            log_warn "    Failed to get service name for ID: $SVC_ID"
            log_warn "    Response (first 300 chars): ${SVC_DETAIL:0:300}"
        else
            SERVICE_IDS[$SVC_NAME]=$SVC_ID
            log_info "    ✓ Collected service: $SVC_NAME -> $SVC_ID"
        fi
    done
done

# Deploy instances in order
DEPLOYMENT_ORDER=$(yq e '.deployment_order' "$CONFIG_FILE" -o=json)
NUM_SERVICES=$(echo "$DEPLOYMENT_ORDER" | jq 'length')

echo ""
log_step "Deploying service instances..."

# Debug: Show all collected service IDs
log_info "Available services:"
for svc in "${!SERVICE_IDS[@]}"; do
    log_info "  - $svc: ${SERVICE_IDS[$svc]}"
done

for i in $(seq 0 $((NUM_SERVICES - 1))); do
    SVC_NAME=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].service")
    INSTANCES=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].instances")
    WAIT_TIME=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].wait_time")

    SVC_ID="${SERVICE_IDS[$SVC_NAME]}"

    if [ -z "$SVC_ID" ] || [ "$SVC_ID" = "null" ]; then
        log_error "Service ID not found for: $SVC_NAME"
        log_error "Available services: ${!SERVICE_IDS[@]}"
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

    # Readiness check
    READINESS_ENABLED=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.enabled // false")

    if [ "$READINESS_ENABLED" = "true" ]; then
        CHECK_TYPE=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.type")
        TIMEOUT=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.timeout")
        RETRIES=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.retries")
        RETRY_DELAY=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.retry_delay")

        if [ "$CHECK_TYPE" = "tcp" ]; then
            HOST=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.host")
            PORT=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.port")

            if ! check_readiness "$SVC_NAME" "tcp" "$TIMEOUT" "$RETRIES" "$RETRY_DELAY" "$HOST" "$PORT"; then
                log_error "Deployment failed: $SVC_NAME not ready"
                exit 1
            fi

        elif [ "$CHECK_TYPE" = "http" ]; then
            ENDPOINT=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.endpoint")
            EXPECTED_STATUSES=$(echo "$DEPLOYMENT_ORDER" | jq -r ".[$i].readiness_check.expected_status[]" | tr '\n' ' ')

            if ! check_readiness "$SVC_NAME" "http" "$TIMEOUT" "$RETRIES" "$RETRY_DELAY" "$ENDPOINT" "$EXPECTED_STATUSES"; then
                log_error "Deployment failed: $SVC_NAME not ready"
                exit 1
            fi
        fi
    elif [ "$i" -lt $((NUM_SERVICES - 1)) ]; then
        # Fall back to wait time if no readiness check configured
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

# Get nginxingress worker node IP
INGRESS_SERVICE_ID="${SERVICE_IDS[nginxingress]}"
if [ -n "$INGRESS_SERVICE_ID" ]; then
    log_info "Retrieving ingress worker node IP..."
    INSTANCES_RESPONSE=$(curl -s -X GET "${BASE_URL}/api/service/${INGRESS_SERVICE_ID}/instance" \
        -H "Authorization: Bearer $TOKEN")
    WORKER_IP=$(echo "$INSTANCES_RESPONSE" | sed 's/^"\(.*\)"$/\1/' | sed 's/\\"/"/g' | jq -r '.[0].public_ip // empty')

    if [ -n "$WORKER_IP" ]; then
        log_info "Access: http://${WORKER_IP}:80"
    else
        log_warn "Could not retrieve worker IP - using service IP"
        log_info "Access: http://10.30.13.13:80"
    fi
else
    log_info "Access: http://10.30.13.13:80"
fi

log_info "Credentials: uid0@email.com / password"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"