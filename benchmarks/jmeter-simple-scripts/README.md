# JMeter Benchmarking for Acorn

This directory contains JMeter benchmark scripts that use pre-built Docker images from the registry.

## Docker Images Used

- **Loop-based**: `schubbcasten/acmeair-jmeter:v0.0.1` - Fixed iteration benchmarks
- **Duration-based**: `schubbcasten/acmeair-jmeter:duration-v0.0.1` - Time-based continuous load

## Scripts

### 1. `run-benchmark.sh` - Standard Benchmark
Fixed number of iterations, good for repeatable benchmarks.

```bash
# Run with defaults (10 threads, 100 loops)
./run-benchmark.sh

# Custom benchmark
TARGET_HOST=192.168.1.207 TARGET_PORT=9080 NUM_THREADS=20 LOOP_COUNT=50 ./run-benchmark.sh

# Override Docker image
IMAGE_NAME=schubbcasten/acmeair-jmeter:v0.0.2 ./run-benchmark.sh
```

### 2. `run-continuous-load.sh` - Continuous Load Test
Runs for a specific time period in foreground.

```bash
# Run for 30 minutes
DURATION=1800 NUM_THREADS=10 TARGET_HOST=myapp.com ./run-continuous-load.sh

# Run for 1 hour
DURATION=3600 NUM_THREADS=5 TARGET_HOST=localhost TARGET_PORT=8080 ./run-continuous-load.sh
```

### 3. `run-background-load.sh` - Background Base Load
Runs as a background Docker container, perfect for base load while running other benchmarks.

```bash
# Start base load (2 hours default)
NUM_THREADS=5 DURATION=7200 TARGET_HOST=localhost ./run-background-load.sh start

# Check status
./run-background-load.sh status

# View logs
./run-background-load.sh logs

# Stop
./run-background-load.sh stop
```

### 4. `analyze-results.sh` - Results Analyzer
Analyzes JMeter .jtl result files.

Example Usage:

```bash
# Analyze full file (no filtering)
./analyze-jmeter-results.sh results.jtl

# Analyze only entries between two timestamps
./analyze-jmeter-results.sh results.jtl 1765301556275495512 1765301586275495512

# Analyze entries after a specific timestamp (no end time)
./analyze-jmeter-results.sh results.jtl 1765301556275495512

# Analyze entries before a specific timestamp (no start time)
./analyze-jmeter-results.sh results.jtl "" 1765301586275495512
```

#### Metrics Reported

  ---

Total Samples
- Count of all requests in the JTL file (excluding header)
- awk -F',' 'END {print NR-1}'

Successful/Failed Requests
- Success: Rows where column 8 (success field) == "true"
- Failed: Rows where column 8 == "false"

Success Rate
- (Successful Requests / Total Samples) * 100

Test Duration
- Last timestamp - First timestamp (from column 1)
- Shown in minutes, seconds, and milliseconds

Throughput
- Total Samples / Duration in seconds
- Requests per second

  ---
Performance Metrics

Response Times (column 2: elapsed)
- Average, Min, Max of response time for successful requests only
- Time from sending request to receiving complete response

Latency (column 15: Latency)
- Average, Min, Max of time to first byte for successful requests
- Network latency - time until first byte received

Request Type Distribution
- Count by request label (column 3)
- Shows breakdown: Login, QueryFlight, BookFlight, etc.

  ---
Recovery Metrics

Total Outages Detected (column 24: TOTAL_OUTAGES)
- Maximum value found across all rows
- Filters out "null" and non-numeric values
- Each endpoint (QueryFlight, Login, etc.) has its own circuit breaker counter

Recovery Times (column 23: LAST_RECOVERY_TIME_MS)
- Time it took for the health check to succeed after circuit breaker opened
- Collected once per outage (when TOTAL_OUTAGES increments)
- Shows: Average, Fastest, Slowest

Maximum Continuous Outage Duration (column 25: CURRENT_OUTAGE_DURATION_MS)
- Longest period any circuit breaker was continuously open
- Maximum value across all rows

Total Downtime (column 21: SERVICE_AVAILABLE)
- Sum of elapsed time (response time) for all requests where SERVICE_AVAILABLE == "false"
- Represents time spent with circuit breaker(s) open
- Shown as seconds and percentage of test duration

Service Availability
- 100% - (Total Downtime / Test Duration) * 100
- Percentage of time service was available

  ---
Outage Timeline

Aggregated Service State Transitions
- Tracks when SERVICE_AVAILABLE changes from "true" → "false" (service unavailable)
- Tracks when SERVICE_AVAILABLE changes from "false" → "true" (service recovered)
- Shows timestamps and duration of each unavailability window
- Aggregated view: ANY endpoint circuit breaker open = service unavailable

  ---
Failure Analysis

Peak Consecutive Failures (column 22: CONSECUTIVE_FAILURES)
- Maximum value of consecutive failure counter
- Shows how many failures in a row before circuit breaker opened

Failed Request Response Codes (column 4: responseCode)
- Distribution of HTTP status codes for failed requests
- e.g., 403, 500, 504, SocketTimeoutException

  ---
Summary / RTO Assessment

Average Recovery Time
- Mean of all LAST_RECOVERY_TIME_MS values across outages

RTO (Recovery Time Objective) Assessment
- ✓ Excellent: < 60 seconds
- ⚠ Acceptable: < 5 minutes
- ✗ Needs Improvement: > 5 minutes

Availability Assessment
- ✓ Excellent: ≥ 99.9% (three nines)
- ⚠ Good: ≥ 99.0%
- ✗ Needs Improvement: < 99%

  ---
Key Columns Reference

| Column | Name                       | Description                             |
  |--------|----------------------------|-----------------------------------------|
| 1      | timeStamp                  | Request timestamp (ms since epoch)      |
| 2      | elapsed                    | Response time (ms)                      |
| 3      | label                      | Request type (Login, QueryFlight, etc.) |
| 4      | responseCode               | HTTP status code                        |
| 8      | success                    | true/false                              |
| 15     | Latency                    | Time to first byte (ms)                 |
| 21     | SERVICE_AVAILABLE          | Circuit breaker state (true/false)      |
| 22     | CONSECUTIVE_FAILURES       | Failure counter                         |
| 23     | LAST_RECOVERY_TIME_MS      | Health check success time               |
| 24     | TOTAL_OUTAGES              | Outage counter                          |
| 25     | CURRENT_OUTAGE_DURATION_MS | Current outage elapsed time             |

----
## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET_HOST` | localhost | Target server IP/hostname |
| `TARGET_PORT` | 8080 | Target server port |
| `NUM_THREADS` | 10 (5 for background) | Concurrent virtual users |
| `LOOP_COUNT` | 100 | Number of iterations (loop-based only) |
| `DURATION` | 3600/7200 | Test duration in seconds (duration-based only) |
| `CONTEXT_ROOT` | (empty) | Optional URL prefix |
| `IMAGE_NAME` | (see above) | Docker image to use |

## Typical Workflow: Base Load + Benchmark

Run a continuous base load while executing spike tests:

```bash
# 1. Start background base load (light, continuous)
NUM_THREADS=5 DURATION=3600 TARGET_HOST=myapp.com ./run-background-load.sh start

# 2. Run your main benchmark on top
NUM_THREADS=50 LOOP_COUNT=100 TARGET_HOST=myapp.com ./run-benchmark.sh

# 3. Check base load status
./run-background-load.sh status

# 4. Stop base load when done
./run-background-load.sh stop

# 5. Analyze results
./analyze-results.sh results/benchmark-*/AcmeAir1.jtl
./analyze-results.sh results/baseload/baseload-*.jtl
```

## Results Directory Structure

```
benchmarks/jmeter/
├── results/
│   ├── benchmark-<timestamp>/
│   │   ├── AcmeAir1.log
│   │   └── AcmeAir1.jtl
│   ├── continuous-<timestamp>/
│   │   ├── continuous-load.log
│   │   └── continuous-load.jtl
│   └── baseload/
│       ├── baseload-<timestamp>.log
│       └── baseload-<timestamp>.jtl
```

## Prerequisites

- Docker installed and running
- Access to Docker Hub to pull images (or images pre-pulled)
- Target application must be running and accessible

## Pulling Images Manually

```bash
# Pull loop-based image
docker pull schubbcasten/acmeair-jmeter:v0.0.1

# Pull duration-based image
docker pull schubbcasten/acmeair-jmeter:duration-v0.0.1
```

## Notes

- These scripts use external Docker images and don't require building locally
- All scripts automatically create timestamped result directories
- The background load controller manages the container lifecycle
- Results are in JMeter's standard .jtl format (XML)
- The analyze-results.sh script provides quick insights without GUI tools

## Application Requirements

The JMeter test plan expects:
- Application running on specified host:port
- Database preloaded with test data (10k customers: uid0@email.com through uid9999@email.com, password: "password")
- Endpoints following AcmeAir API structure

## Quick Start

```bash
# Make scripts executable
chmod +x *.sh

# Run a quick test
TARGET_HOST=localhost TARGET_PORT=8080 NUM_THREADS=5 LOOP_COUNT=10 ./run-benchmark.sh

# Analyze results
./analyze-results.sh results/benchmark-*/AcmeAir1.jtl
```