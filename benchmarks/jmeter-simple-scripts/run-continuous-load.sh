#!/bin/bash
#
# JMeter Continuous Load Runner (Duration-based)
# Uses pre-built duration Docker image from registry
#

set -e

# Configuration
TARGET_HOST="${TARGET_HOST:-localhost}"
TARGET_PORT="${TARGET_PORT:-8080}"
NUM_THREADS="${NUM_THREADS:-10}"
DURATION="${DURATION:-3600}"  # Duration in seconds (default: 1 hour)
CONTEXT_ROOT="${CONTEXT_ROOT:-}"
IMAGE_NAME="${IMAGE_NAME:-schubbcasten/acmeair-jmeter-resilient:v1.1.2}"

echo "================================================"
echo "JMeter Continuous Load Generator"
echo "================================================"
echo "Target: http://${TARGET_HOST}:${TARGET_PORT}${CONTEXT_ROOT}"
echo "Threads: ${NUM_THREADS}"
echo "Duration: ${DURATION} seconds ($(echo "scale=2; ${DURATION}/60" | bc) minutes)"
echo "Image: ${IMAGE_NAME}"
echo "================================================"
echo ""

# Create results directory
mkdir -p results
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_DIR="results/continuous-${TIMESTAMP}"
mkdir -p "${RESULT_DIR}"

echo "Starting continuous load test..."
echo "Results will be saved to: ${RESULT_DIR}/"
echo "Press Ctrl+C to stop early (JMeter will finish current transactions)"
echo ""

# Trap Ctrl+C to show results location
trap 'echo ""; echo "Stopping..."; echo "Results saved in: ${RESULT_DIR}/"; exit 0' INT TERM

# Run JMeter with duration parameter
docker run --rm \
    --name jmeter-continuous-${TIMESTAMP} \
    -e NUM_THREAD=${NUM_THREADS} \
    -e DURATION=${DURATION} \
    -e USE_PURE_IDS=true \
    -e LOG_FILE=continuous-load.log \
    -e JTL_FILE=continuous-load.jtl \
    -e APP_PORT_9080_TCP_ADDR=${TARGET_HOST} \
    -e APP_PORT_9080_TCP_PORT=${TARGET_PORT} \
    -e CONTEXT_ROOT=${CONTEXT_ROOT} \
    -v $(pwd)/${RESULT_DIR}:/var/workload/acmeair-nodejs/logs \
    ${IMAGE_NAME}

echo ""
echo "================================================"
echo "Continuous load test completed!"
echo "Results saved in: ${RESULT_DIR}/"
echo "  - continuous-load.log (JMeter log)"
echo "  - continuous-load.jtl (Test results)"
echo ""
echo "Analyze results with:"
echo "  ./analyze-results.sh ${RESULT_DIR}/continuous-load.jtl"
echo "================================================"