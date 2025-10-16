#!/opt/homebrew/bin/bash
set -e

# Benchmark automation script for Acorn distributed benchmarking system
# This script orchestrates the entire benchmark workflow:
# 1. Pull latest code on all nodes
# 2. Start orchestrator (lair)
# 3. Start workers (acorn)
# 4. Trigger benchmark execution via gRPC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ACORN_DIR="/home/carsten/workspace/acorn"
SSH_USER="root"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Load infrastructure information from Terraform
load_infrastructure() {
    log_info "Loading infrastructure information from Terraform..."

    cd "$PROJECT_DIR/terraform"

    if ! terraform output -json > /tmp/terraform_output.json 2>/dev/null; then
        log_error "Failed to load Terraform outputs. Make sure infrastructure is deployed."
        exit 1
    fi

    ORCHESTRATOR_IP=$(jq -r '.orchestrator_public_ipv4.value' /tmp/terraform_output.json)
    ORCHESTRATOR_PRIVATE_IP=$(jq -r '.orchestrator_private_ipv4.value' /tmp/terraform_output.json)

    # Parse worker IPs into arrays
    mapfile -t WORKER_IPS < <(jq -r '.worker_public_ipv4s.value[]' /tmp/terraform_output.json)
    mapfile -t WORKER_PRIVATE_IPS < <(jq -r '.worker_private_ipv4s.value[]' /tmp/terraform_output.json)

    WORKER_COUNT=${#WORKER_IPS[@]}

    log_success "Infrastructure loaded:"
    log_info "  Orchestrator: $ORCHESTRATOR_IP (private: $ORCHESTRATOR_PRIVATE_IP)"
    log_info "  Workers: $WORKER_COUNT node(s)"
    for i in "${!WORKER_IPS[@]}"; do
        log_info "    Worker $((i+1)): ${WORKER_IPS[$i]} (private: ${WORKER_PRIVATE_IPS[$i]})"
    done

    cd "$PROJECT_DIR"
}

# Git pull on a remote node
git_pull_node() {
    local node_ip=$1
    local node_name=$2

    log_info "[$node_name] Pulling latest code from git..."

    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$node_ip" \
        "cd $ACORN_DIR && sudo -u carsten git pull --force"; then
        log_success "[$node_name] Code updated successfully"
        return 0
    else
        log_error "[$node_name] Failed to pull code"
        return 1
    fi
}

# Git pull on all nodes
pull_all_nodes() {
    log_info "Updating code on all nodes..."

    local failed=0

    # Pull on orchestrator
    git_pull_node "$ORCHESTRATOR_IP" "orchestrator" || ((failed++))

    # Pull on all workers
    for i in "${!WORKER_IPS[@]}"; do
        git_pull_node "${WORKER_IPS[$i]}" "worker-$((i+1))" || ((failed++))
    done

    if [ $failed -gt 0 ]; then
        log_error "Failed to update code on $failed node(s)"
        return 1
    fi

    log_success "All nodes updated successfully"
    return 0
}

# Build the project on a node
build_node() {
    local node_ip=$1
    local node_name=$2

    log_info "[$node_name] Building project..."

    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$node_ip" \
    "cd $ACORN_DIR && sudo -u carsten mkdir -p bin && sudo -u carsten sh -c 'cd $ACORN_DIR && /usr/local/go/bin/go build -o bin/lair ./lair && /usr/local/go/bin/go build -o bin/acorn ./acorn && chmod +x bin/lair bin/acorn'"; then
        log_success "[${node_name}] Build completed"
        return 0
    else
        log_error "[$node_name] Build failed"
        return 1
    fi
}

# Build on all nodes
build_all_nodes() {
    log_info "Building project on all nodes..."

    local failed=0

    # Build on orchestrator
    build_node "$ORCHESTRATOR_IP" "orchestrator" || ((failed++))

    # Build on all workers
    for i in "${!WORKER_IPS[@]}"; do
        build_node "${WORKER_IPS[$i]}" "worker-$((i+1))" || ((failed++))
    done

    if [ $failed -gt 0 ]; then
        log_error "Failed to build on $failed node(s)"
        return 1
    fi

    log_success "All nodes built successfully"
    return 0
}

# Kill existing processes on a node
kill_processes_node() {
    local node_ip=$1
    local node_name=$2
    local process_pattern=$3

    log_info "[$node_name] Killing existing $process_pattern processes..."

    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$node_ip" \
        "pkill -f '$process_pattern' 2>/dev/null || true" || true

    log_success "[$node_name] Processes killed"
}

# Start orchestrator (lair)
start_orchestrator() {
    log_info "Starting orchestrator (lair)..."

    # Kill any existing lair processes
    kill_processes_node "$ORCHESTRATOR_IP" "orchestrator" "bin/lair"
    log_info "After killing processes"

    # Start lair in background
    log_info "Starting lair binary..."
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$ORCHESTRATOR_IP" \
        "cd $ACORN_DIR && nohup ./bin/lair > /tmp/lair.log 2>&1 &"; then
        log_info "SSH command succeeded"
    else
        log_error "SSH command failed with exit code $?"
        return 1
    fi

    # Wait a bit for the orchestrator to start
    sleep 2

    # Check if orchestrator is running
    if ssh -o StrictHostKeyChecking=no "$SSH_USER@$ORCHESTRATOR_IP" \
        "netstat -tuln | grep -q ':50051'"; then
        log_success "Orchestrator started successfully on port 50051"
        return 0
    else
        log_error "Orchestrator failed to start. Check logs at /tmp/lair.log"
        return 1
    fi
}

# Start a worker node (acorn)
start_worker() {
    local worker_ip=$1
    local worker_idx=$2

    log_info "[worker-$worker_idx] Starting acorn worker..."

    # Kill any existing acorn processes
    kill_processes_node "$worker_ip" "worker-$worker_idx" "bin/acorn"

    # Start acorn in background, connecting to orchestrator's private IP
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$worker_ip" \
        "cd $ACORN_DIR && nohup ./bin/acorn --server $ORCHESTRATOR_PRIVATE_IP:50051 > /tmp/acorn.log 2>&1 &"

    # Wait a bit for the worker to start
    sleep 1

    # Check if worker is running
    if ssh -o StrictHostKeyChecking=no "$SSH_USER@$worker_ip" \
        "netstat -tuln | grep -q ':60051'"; then
        log_success "[worker-$worker_idx] Worker started successfully on port 60051"
        return 0
    else
        log_warning "[worker-$worker_idx] Worker may not have started. Check logs at /tmp/acorn.log"
        return 1
    fi
}

# Start all workers
start_all_workers() {
    log_info "Starting all worker nodes..."

    local failed=0

    for i in "${!WORKER_IPS[@]}"; do
        start_worker "${WORKER_IPS[$i]}" "$((i+1))" || ((failed++))
    done

    if [ $failed -gt 0 ]; then
        log_warning "$failed worker(s) may have failed to start"
    else
        log_success "All workers started successfully"
    fi

    # Wait for workers to register with orchestrator
    log_info "Waiting for workers to register with orchestrator..."
    sleep 5

    return 0
}

# Trigger benchmark via gRPC
trigger_benchmark() {
    log_info "Triggering benchmark execution..."

    # Build and use the benchmark trigger client
    cd "$PROJECT_DIR"

    # Build the trigger binary if it doesn't exist or source is newer
    if [ ! -f "bin/benchmark-trigger" ] || [ "cmd/benchmark-trigger" -nt "bin/benchmark-trigger" ]; then
        log_info "Building benchmark-trigger..."
        go build -o bin/benchmark-trigger ./cmd/benchmark-trigger
    fi

    if ./bin/benchmark-trigger --server "$ORCHESTRATOR_IP:50051"; then
        log_success "Benchmark started successfully!"
        return 0
    else
        log_error "Failed to trigger benchmark"
        return 1
    fi
}

# Collect logs from all nodes
collect_logs() {
    log_info "Collecting logs from all nodes..."

    local log_dir="$PROJECT_DIR/benchmark-logs/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$log_dir"

    # Collect from orchestrator
    log_info "Collecting orchestrator logs..."
    scp -o StrictHostKeyChecking=no "$SSH_USER@$ORCHESTRATOR_IP:/tmp/lair.log" \
        "$log_dir/orchestrator.log" 2>/dev/null || log_warning "Failed to collect orchestrator logs"

    # Collect from workers
    for i in "${!WORKER_IPS[@]}"; do
        log_info "Collecting logs from worker-$((i+1))..."
        scp -o StrictHostKeyChecking=no "$SSH_USER@${WORKER_IPS[$i]}:/tmp/acorn.log" \
            "$log_dir/worker-$((i+1)).log" 2>/dev/null || log_warning "Failed to collect worker-$((i+1)) logs"

        # Also collect fallback logs if they exist
        scp -o StrictHostKeyChecking=no "$SSH_USER@${WORKER_IPS[$i]}:$ACORN_DIR/loki_fallback.log" \
            "$log_dir/worker-$((i+1))-fallback.log" 2>/dev/null || true
    done

    log_success "Logs collected to: $log_dir"
}

# Main execution flow
main() {
    log_info "Starting Acorn benchmark automation..."
    echo ""

    # Load infrastructure
    load_infrastructure
    echo ""

    # Parse command line arguments
    SKIP_PULL=false
    SKIP_BUILD=false
    COLLECT_LOGS_ONLY=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-pull)
                SKIP_PULL=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --collect-logs)
                COLLECT_LOGS_ONLY=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--skip-pull] [--skip-build] [--collect-logs]"
                exit 1
                ;;
        esac
    done

    # Collect logs only if requested
    if [ "$COLLECT_LOGS_ONLY" = true ]; then
        collect_logs
        exit 0
    fi

    # Step 1: Pull latest code
    if [ "$SKIP_PULL" = false ]; then
        pull_all_nodes
        echo ""
    else
        log_warning "Skipping git pull (--skip-pull)"
        echo ""
    fi

    # Step 2: Build project
    if [ "$SKIP_BUILD" = false ]; then
        build_all_nodes
        echo ""
    else
        log_warning "Skipping build (--skip-build)"
        echo ""
    fi

    # Step 3: Start orchestrator
    start_orchestrator
    echo ""

    # Step 4: Start workers
    start_all_workers
    echo ""

    # Step 5: Trigger benchmark
    trigger_benchmark
    echo ""

    log_info "Benchmark is now running!"
    log_info "You can collect logs later with: $0 --collect-logs"

    echo ""
    log_success "Automation completed successfully!"
}

# Run main function
main "$@"