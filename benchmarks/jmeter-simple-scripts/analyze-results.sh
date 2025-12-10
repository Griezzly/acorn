#!/bin/bash
#*******************************************************************************
#* Recovery Metrics Analysis Script for AcmeAir JMeter Results
#*
#* This script analyzes JTL files from resilient JMeter runs and extracts
#* recovery metrics including downtime, recovery times, and outage counts.
#*
#* Usage: ./analyze-jmeter-results.sh <jtl-file> [start-timestamp] [end-timestamp]
#*
#* Timestamps should be in nanoseconds (e.g., 1765301556275495512)
#* If provided, only entries within the timestamp range will be analyzed
#*******************************************************************************

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# Check for input file
if [ -z "$1" ]; then
    echo -e "${RED}Error: No JTL file specified${NC}"
    echo "Usage: $0 <jtl-file> [start-timestamp-ns] [end-timestamp-ns]"
    echo ""
    echo "Example:"
    echo "  $0 results.jtl"
    echo "  $0 jmeter-results/AcmeAir1.jtl"
    echo "  $0 results.jtl 1765301556275495512 1765301586275495512"
    exit 1
fi

JTL_FILE="$1"
START_TIMESTAMP_NS="$2"
END_TIMESTAMP_NS="$3"

# Convert nanosecond timestamps to milliseconds (JMeter format)
START_TIMESTAMP_MS=""
END_TIMESTAMP_MS=""
if [ ! -z "$START_TIMESTAMP_NS" ]; then
    START_TIMESTAMP_MS=$((START_TIMESTAMP_NS / 1000000))
fi
if [ ! -z "$END_TIMESTAMP_NS" ]; then
    END_TIMESTAMP_MS=$((END_TIMESTAMP_NS / 1000000))
fi

if [ ! -f "$JTL_FILE" ]; then
    echo -e "${RED}Error: File not found: $JTL_FILE${NC}"
    exit 1
fi

# Create filtered file if timestamps provided
FILTERED_FILE=""
if [ ! -z "$START_TIMESTAMP_MS" ] || [ ! -z "$END_TIMESTAMP_MS" ]; then
    FILTERED_FILE=$(mktemp)

    # Extract header
    head -1 "$JTL_FILE" > "$FILTERED_FILE"

    # Filter data rows based on timestamps
    awk -F',' -v start="$START_TIMESTAMP_MS" -v end="$END_TIMESTAMP_MS" '
        NR>1 {
            timestamp=$1
            include=1
            if (start != "" && timestamp < start) include=0
            if (end != "" && timestamp > end) include=0
            if (include) print $0
        }
    ' "$JTL_FILE" >> "$FILTERED_FILE"

    # Use filtered file for analysis
    JTL_FILE="$FILTERED_FILE"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Recovery Metrics Analysis Report${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "File: $1"
if [ ! -z "$START_TIMESTAMP_MS" ] || [ ! -z "$END_TIMESTAMP_MS" ]; then
    echo "Timestamp Filter: ENABLED"
    if [ ! -z "$START_TIMESTAMP_MS" ]; then
        echo "  Start: $START_TIMESTAMP_NS (ns) = $START_TIMESTAMP_MS (ms) = $(date -r $((START_TIMESTAMP_MS/1000)) '+%Y-%m-%d %H:%M:%S')"
    fi
    if [ ! -z "$END_TIMESTAMP_MS" ]; then
        echo "  End:   $END_TIMESTAMP_NS (ns) = $END_TIMESTAMP_MS (ms) = $(date -r $((END_TIMESTAMP_MS/1000)) '+%Y-%m-%d %H:%M:%S')"
    fi
fi
echo "Generated: $(date)"
echo ""

# Check if file has recovery metrics
HAS_RECOVERY_METRICS=false
if head -1 "$JTL_FILE" | grep -q "SERVICE_AVAILABLE"; then
    HAS_RECOVERY_METRICS=true
else
    echo -e "${YELLOW}Note: Recovery metrics not found in this JTL file.${NC}"
    echo "Showing standard performance metrics only."
    echo ""
fi

echo -e "${BLUE}=== Basic Test Statistics ===${NC}"
echo ""

# Total samples
TOTAL_SAMPLES=$(awk -F',' 'END {print NR-1}' "$JTL_FILE")
echo "Total Samples: $TOTAL_SAMPLES"

# Success/Failure counts
SUCCESS_COUNT=$(awk -F',' 'NR>1 && $8=="true" {count++} END {print count+0}' "$JTL_FILE")
FAILURE_COUNT=$(awk -F',' 'NR>1 && $8=="false" {count++} END {print count+0}' "$JTL_FILE")
echo "Successful Requests: $SUCCESS_COUNT"
echo "Failed Requests: $FAILURE_COUNT"

# Calculate success rate
if [ "$TOTAL_SAMPLES" -gt 0 ]; then
    SUCCESS_RATE=$(awk "BEGIN {printf \"%.2f\", ($SUCCESS_COUNT/$TOTAL_SAMPLES)*100}")
    echo "Success Rate: ${SUCCESS_RATE}%"
fi

# Test duration
START_TIME=$(awk -F',' 'NR==2 {print $1}' "$JTL_FILE")
END_TIME=$(awk -F',' 'END {print $1}' "$JTL_FILE")
DURATION_MS=$((END_TIME - START_TIME))
DURATION_SEC=$((DURATION_MS / 1000))
DURATION_MIN=$((DURATION_SEC / 60))

echo "Test Duration: ${DURATION_MIN}m ${DURATION_SEC}s (${DURATION_MS}ms)"

# Throughput
if [ "$DURATION_SEC" -gt 0 ]; then
    THROUGHPUT=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SAMPLES/$DURATION_SEC}")
    echo "Throughput: ${THROUGHPUT} requests/second"
fi

echo ""

echo -e "${BLUE}=== Performance Metrics ===${NC}"
echo ""

# Response time statistics
awk -F',' '
    NR>1 && $8=="true" {
        elapsed=$2
        sum+=elapsed
        count++
        if (count==1 || elapsed<min) min=elapsed
        if (count==1 || elapsed>max) max=elapsed
    }
    END {
        if (count>0) {
            printf "Response Times (Successful Requests):\n"
            printf "  Average: %.2f ms\n", sum/count
            printf "  Min: %d ms\n", min
            printf "  Max: %d ms\n", max
        }
    }
' "$JTL_FILE"

# Latency statistics (column 15 based on the header)
awk -F',' '
    NR>1 && $8=="true" && $15>0 {
        latency=$15
        sum+=latency
        count++
        if (count==1 || latency<min) min=latency
        if (count==1 || latency>max) max=latency
    }
    END {
        if (count>0) {
            printf "\nLatency (Time to First Byte):\n"
            printf "  Average: %.2f ms\n", sum/count
            printf "  Min: %d ms\n", min
            printf "  Max: %d ms\n", max
        }
    }
' "$JTL_FILE"

# Request type breakdown
echo ""
echo "Request Type Distribution:"
awk -F',' 'NR>1 {types[$3]++} END {for(type in types) printf "  %s: %d requests\n", type, types[type]}' "$JTL_FILE" | sort

echo ""

if [ "$HAS_RECOVERY_METRICS" = true ]; then
    echo -e "${BLUE}=== Recovery Metrics ===${NC}"
    echo ""

    # Find column indices for recovery metrics
    HEADER=$(head -1 "$JTL_FILE")
    SERVICE_AVAILABLE_COL=$(echo "$HEADER" | awk -F',' '{for(i=1;i<=NF;i++) if($i=="SERVICE_AVAILABLE") print i}')
    CONSECUTIVE_FAILURES_COL=$(echo "$HEADER" | awk -F',' '{for(i=1;i<=NF;i++) if($i=="CONSECUTIVE_FAILURES") print i}')
    LAST_RECOVERY_TIME_COL=$(echo "$HEADER" | awk -F',' '{for(i=1;i<=NF;i++) if($i=="LAST_RECOVERY_TIME_MS") print i}')
    TOTAL_OUTAGES_COL=$(echo "$HEADER" | awk -F',' '{for(i=1;i<=NF;i++) if($i=="TOTAL_OUTAGES") print i}')
    CURRENT_OUTAGE_DURATION_COL=$(echo "$HEADER" | awk -F',' '{for(i=1;i<=NF;i++) if($i=="CURRENT_OUTAGE_DURATION_MS") print i}')

    # Verify we found the columns
    if [ -z "$TOTAL_OUTAGES_COL" ]; then
        echo -e "${YELLOW}Warning: Recovery metric columns not found. Skipping recovery analysis.${NC}"
        HAS_RECOVERY_METRICS=false
    fi
fi

if [ "$HAS_RECOVERY_METRICS" = true ]; then
    # Total outages
    TOTAL_OUTAGES=$(awk -F',' -v col="$TOTAL_OUTAGES_COL" 'NR>1 && $col>max {max=$col} END {print max+0}' "$JTL_FILE")
echo "Total Outages Detected: $TOTAL_OUTAGES"

# Recovery times
if [ "$TOTAL_OUTAGES" -gt 0 ]; then
    echo ""
    echo "Recovery Times:"
    awk -F',' -v col="$LAST_RECOVERY_TIME_COL" '
        NR>1 && $col>0 && prev!=$col {
            printf "  Outage #%d: %.2f seconds (%s ms)\n", ++count, $col/1000, $col
            sum+=$col
            if ($col > max) max=$col
            if (min==0 || $col < min) min=$col
            prev=$col
        }
        END {
            if (count>0) {
                printf "\n"
                printf "  Average Recovery Time: %.2f seconds\n", sum/count/1000
                printf "  Fastest Recovery: %.2f seconds\n", min/1000
                printf "  Slowest Recovery: %.2f seconds\n", max/1000
            }
        }
    ' "$JTL_FILE"
else
    echo "  No outages detected during test"
fi

echo ""

# Maximum outage duration
MAX_OUTAGE_DURATION=$(awk -F',' -v col="$CURRENT_OUTAGE_DURATION_COL" 'NR>1 && $col>max {max=$col} END {print max+0}' "$JTL_FILE")
if [ "$MAX_OUTAGE_DURATION" -gt 0 ]; then
    MAX_OUTAGE_SEC=$(awk "BEGIN {printf \"%.2f\", $MAX_OUTAGE_DURATION/1000}")
    echo "Maximum Continuous Outage Duration: ${MAX_OUTAGE_SEC}s (${MAX_OUTAGE_DURATION}ms)"
fi

# Calculate total downtime
TOTAL_DOWNTIME=$(awk -F',' -v sa_col="$SERVICE_AVAILABLE_COL" '
    NR>1 && $sa_col=="false" {downtime+=$2}
    END {print downtime+0}
' "$JTL_FILE")

if [ "$TOTAL_DOWNTIME" -gt 0 ]; then
    DOWNTIME_SEC=$(awk "BEGIN {printf \"%.2f\", $TOTAL_DOWNTIME/1000}")
    DOWNTIME_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_DOWNTIME/$DURATION_MS)*100}")
    echo "Total Downtime: ${DOWNTIME_SEC}s (${DOWNTIME_PERCENT}% of test duration)"

    # Calculate availability
    AVAILABILITY=$(awk "BEGIN {printf \"%.3f\", 100 - $DOWNTIME_PERCENT}")
    echo "Service Availability: ${AVAILABILITY}%"
else
    echo "Total Downtime: 0s"
    echo "Service Availability: 100.000%"
fi

echo ""

echo -e "${BLUE}=== Outage Timeline ===${NC}"
echo ""

if [ "$TOTAL_OUTAGES" -gt 0 ]; then
    awk -F',' -v sa_col="$SERVICE_AVAILABLE_COL" -v rt_col="$LAST_RECOVERY_TIME_COL" '
        NR>1 {
            if ($sa_col=="false" && !outage_active) {
                outage_start=$1
                outage_num++
                outage_active=1
                printf "[%s] Outage #%d started\n", strftime("%Y-%m-%d %H:%M:%S", $1/1000), outage_num
            }
            if ($sa_col=="true" && outage_active && $rt_col>0 && prev_rt!=$rt_col) {
                recovery_time = $1 - outage_start
                printf "[%s] Outage #%d ended (Duration: %.2fs, Recovery: %.2fs)\n",
                    strftime("%Y-%m-%d %H:%M:%S", $1/1000), outage_num,
                    recovery_time/1000, $rt_col/1000
                outage_active=0
                prev_rt=$rt_col
            }
        }
    ' "$JTL_FILE"
else
    echo "No outages occurred during this test."
fi

echo ""

echo -e "${BLUE}=== Failure Analysis ===${NC}"
echo ""

# Peak consecutive failures
PEAK_FAILURES=$(awk -F',' -v col="$CONSECUTIVE_FAILURES_COL" 'NR>1 && $col>max {max=$col} END {print max+0}' "$JTL_FILE")
echo "Peak Consecutive Failures: $PEAK_FAILURES"

# Response code distribution for failures
echo ""
echo "Failed Request Response Codes:"
awk -F',' 'NR>1 && $8=="false" {codes[$4]++} END {for(code in codes) printf "  %s: %d\n", code, codes[code]}' "$JTL_FILE" | sort

    echo ""

    echo -e "${BLUE}=== Summary ===${NC}"
    echo ""

    # Calculate RTO (Recovery Time Objective) compliance
    if [ "$TOTAL_OUTAGES" -gt 0 ]; then
    AVG_RECOVERY=$(awk -F',' -v col="$LAST_RECOVERY_TIME_COL" '
        NR>1 && $col>0 && prev!=$col {sum+=$col; count++; prev=$col}
        END {if(count>0) printf "%.2f", sum/count/1000; else print "0"}
    ' "$JTL_FILE")

    echo "✓ Test completed with $TOTAL_OUTAGES outage(s)"
    echo "✓ Average recovery time: ${AVG_RECOVERY}s"
    echo "✓ Service availability: ${AVAILABILITY}%"

    # RTO recommendations
    echo ""
    echo "RTO Assessment:"
    if [ $(echo "$AVG_RECOVERY < 60" | bc -l) -eq 1 ]; then
        echo -e "  ${GREEN}✓ Excellent: Average recovery under 60 seconds${NC}"
    elif [ $(echo "$AVG_RECOVERY < 300" | bc -l) -eq 1 ]; then
        echo -e "  ${YELLOW}⚠ Acceptable: Average recovery under 5 minutes${NC}"
    else
        echo -e "  ${RED}✗ Needs Improvement: Average recovery over 5 minutes${NC}"
    fi

    # Availability recommendations
    if [ $(echo "$AVAILABILITY >= 99.9" | bc -l) -eq 1 ]; then
        echo -e "  ${GREEN}✓ Excellent: 99.9%+ availability (three nines)${NC}"
    elif [ $(echo "$AVAILABILITY >= 99.0" | bc -l) -eq 1 ]; then
        echo -e "  ${YELLOW}⚠ Good: 99%+ availability${NC}"
    else
        echo -e "  ${RED}✗ Needs Improvement: Below 99% availability${NC}"
    fi
    else
        echo "✓ Test completed with no outages"
        echo "✓ Service maintained 100% availability"
    fi
else
    # No recovery metrics - show simple summary
    echo -e "${BLUE}=== Summary ===${NC}"
    echo ""
    echo "✓ Test completed successfully"
    echo "✓ Total Samples: $TOTAL_SAMPLES"
    echo "✓ Success Rate: ${SUCCESS_RATE}%"
    if [ "$DURATION_SEC" -gt 0 ]; then
        echo "✓ Throughput: ${THROUGHPUT} requests/second"
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}End of Report${NC}"
echo -e "${GREEN}========================================${NC}"

# Cleanup temporary filtered file
if [ ! -z "$FILTERED_FILE" ]; then
    rm -f "$FILTERED_FILE"
fi