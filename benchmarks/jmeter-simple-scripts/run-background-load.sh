#!/bin/bash
#
# JMeter Background Base Load Controller
# Uses pre-built duration Docker image from registry
#

# Configuration
TARGET_HOST="${TARGET_HOST:-localhost}"
TARGET_PORT="${TARGET_PORT:-8080}"
NUM_THREADS="${NUM_THREADS:-5}"  # Lower default for base load
DURATION="${DURATION:-7200}"  # Default: 2 hours
CONTEXT_ROOT="${CONTEXT_ROOT:-}"
IMAGE_NAME="${IMAGE_NAME:-schubbcasten/acmeair-jmeter:duration-v0.0.1}"
CONTAINER_NAME="jmeter-baseload"

case "${1:-start}" in
    start)
        echo "================================================"
        echo "Starting Background Base Load"
        echo "================================================"
        echo "Target: http://${TARGET_HOST}:${TARGET_PORT}${CONTEXT_ROOT}"
        echo "Threads: ${NUM_THREADS}"
        echo "Duration: ${DURATION} seconds ($(echo "scale=2; ${DURATION}/60" | bc) minutes)"
        echo "Image: ${IMAGE_NAME}"
        echo "================================================"
        echo ""

        # Check if already running
        if docker ps | grep -q ${CONTAINER_NAME}; then
            echo "Error: Base load is already running!"
            echo "Stop it first with: $0 stop"
            exit 1
        fi

        # Create results directory
        mkdir -p results/baseload
        TIMESTAMP=$(date +%Y%m%d-%H%M%S)

        echo "Starting JMeter in background..."
        echo "Duration: ${DURATION} seconds"

        # Run in detached mode with duration parameter
        docker run -d \
            --name ${CONTAINER_NAME} \
            --restart unless-stopped \
            --cpus="1.0" \
            --memory="512m" \
            -e NUM_THREAD=${NUM_THREADS} \
            -e DURATION=${DURATION} \
            -e USE_PURE_IDS=true \
            -e LOG_FILE=baseload-${TIMESTAMP}.log \
            -e JTL_FILE=baseload-${TIMESTAMP}.jtl \
            -e APP_PORT_9080_TCP_ADDR=${TARGET_HOST} \
            -e APP_PORT_9080_TCP_PORT=${TARGET_PORT} \
            -e CONTEXT_ROOT=${CONTEXT_ROOT} \
            -v $(pwd)/results/baseload:/var/workload/acmeair-nodejs/logs \
            ${IMAGE_NAME}

        if [ $? -eq 0 ]; then
            echo ""
            echo "✓ Base load started successfully!"
            echo "  Container: ${CONTAINER_NAME}"
            echo "  Started: $(date)"
            echo "  Will run for: ${DURATION} seconds"
            echo ""
            echo "Commands:"
            echo "  Status:  $0 status"
            echo "  Logs:    $0 logs"
            echo "  Stop:    $0 stop"
            echo "  Results: ./analyze-results.sh results/baseload/baseload-${TIMESTAMP}.jtl"
        else
            echo "✗ Failed to start base load"
            exit 1
        fi
        ;;

    stop)
        echo "Stopping background base load..."
        if docker ps | grep -q ${CONTAINER_NAME}; then
            docker stop -t 30 ${CONTAINER_NAME}
            docker rm ${CONTAINER_NAME}
            echo "✓ Base load stopped"
            echo ""
            echo "Results available in: ./results/baseload/"
        else
            echo "Base load is not running"
        fi
        ;;

    status)
        if docker ps | grep -q ${CONTAINER_NAME}; then
            echo "✓ Base load is RUNNING"
            echo ""
            docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"
            echo ""
            # Show live stats
            if [ -f results/baseload/baseload-*.jtl ]; then
                LATEST_JTL=$(ls -t results/baseload/baseload-*.jtl | head -1)
                TOTAL=$(grep -c "httpSample" "$LATEST_JTL" 2>/dev/null || echo "0")
                SUCCESS=$(grep -c 's="true"' "$LATEST_JTL" 2>/dev/null || echo "0")
                FAILED=$(grep -c 's="false"' "$LATEST_JTL" 2>/dev/null || echo "0")
                echo "Live Statistics:"
                echo "  Total requests: $TOTAL"
                echo "  Successful: $SUCCESS"
                echo "  Failed: $FAILED"
                if [ "$TOTAL" -gt 0 ]; then
                    SUCCESS_RATE=$(echo "scale=2; $SUCCESS * 100 / $TOTAL" | bc)
                    echo "  Success rate: ${SUCCESS_RATE}%"
                fi
            fi
        else
            echo "✗ Base load is NOT running"
        fi
        ;;

    logs)
        if docker ps | grep -q ${CONTAINER_NAME}; then
            echo "Showing live logs (Ctrl+C to exit)..."
            docker logs -f ${CONTAINER_NAME}
        else
            echo "Base load is not running"
            exit 1
        fi
        ;;

    restart)
        echo "Restarting base load..."
        $0 stop
        sleep 2
        $0 start
        ;;

    *)
        echo "JMeter Background Base Load Controller"
        echo ""
        echo "Usage: $0 {start|stop|status|logs|restart}"
        echo ""
        echo "Commands:"
        echo "  start   - Start background base load"
        echo "  stop    - Stop background base load"
        echo "  status  - Show current status and statistics"
        echo "  logs    - Show live logs"
        echo "  restart - Restart base load"
        echo ""
        echo "Environment variables:"
        echo "  TARGET_HOST   - Target server (default: localhost)"
        echo "  TARGET_PORT   - Target port (default: 8080)"
        echo "  NUM_THREADS   - Number of concurrent users (default: 5)"
        echo "  DURATION      - Duration in seconds (default: 7200)"
        echo "  IMAGE_NAME    - Docker image (default: schubbcasten/acmeair-jmeter:duration-v0.0.1)"
        echo ""
        echo "Examples:"
        echo "  # Start with defaults"
        echo "  $0 start"
        echo ""
        echo "  # Start with custom settings"
        echo "  TARGET_HOST=192.168.1.207 TARGET_PORT=9080 NUM_THREADS=10 DURATION=3600 $0 start"
        echo ""
        echo "  # Check status"
        echo "  $0 status"
        echo ""
        echo "  # Stop"
        echo "  $0 stop"
        ;;
esac