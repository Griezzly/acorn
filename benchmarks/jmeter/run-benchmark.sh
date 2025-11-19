#!/bin/bash
#
# JMeter Benchmark Runner for AcmeAir/Acorn
# Uses pre-built Docker image from registry
#

set -e

# Configuration
TARGET_HOST="${TARGET_HOST:-localhost}"
TARGET_PORT="${TARGET_PORT:-8080}"
NUM_THREADS="${NUM_THREADS:-10}"
LOOP_COUNT="${LOOP_COUNT:-100}"
CONTEXT_ROOT="${CONTEXT_ROOT:-}"
IMAGE_NAME="${IMAGE_NAME:-schubbcasten/acmeair-jmeter:v0.0.1}"

echo "================================================"
echo "JMeter Benchmark Runner"
echo "================================================"
echo "Target: http://${TARGET_HOST}:${TARGET_PORT}${CONTEXT_ROOT}"
echo "Threads: ${NUM_THREADS}"
echo "Loop Count: ${LOOP_COUNT}"
echo "Image: ${IMAGE_NAME}"
echo "================================================"
echo ""

# Create results directory
mkdir -p results
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_DIR="results/benchmark-${TIMESTAMP}"
mkdir -p "${RESULT_DIR}"

echo "Starting JMeter benchmark..."
echo "Results will be saved to: ${RESULT_DIR}/"
echo ""

# Run the benchmark
docker run --rm \
    -e NUM_THREAD=${NUM_THREADS} \
    -e LOOP_COUNT=${LOOP_COUNT} \
    -e USE_PURE_IDS=true \
    -e APP_PORT_9080_TCP_ADDR=${TARGET_HOST} \
    -e APP_PORT_9080_TCP_PORT=${TARGET_PORT} \
    -e CONTEXT_ROOT=${CONTEXT_ROOT} \
    -v $(pwd)/${RESULT_DIR}:/var/workload/acmeair-nodejs/logs \
    ${IMAGE_NAME}

echo ""
echo "================================================"
echo "Benchmark completed!"
echo "Results saved in: ${RESULT_DIR}/"
echo "  - AcmeAir1.log (JMeter log)"
echo "  - AcmeAir1.jtl (Test results)"
echo ""
echo "Analyze results with:"
echo "  ./analyze-results.sh ${RESULT_DIR}/AcmeAir1.jtl"
echo "================================================"