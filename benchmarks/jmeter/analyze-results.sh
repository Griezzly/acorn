#!/bin/bash
#
# Analyze JMeter results from .jtl file
#

JTL_FILE="${1}"

if [ -z "$JTL_FILE" ]; then
    echo "Usage: $0 <path-to-jtl-file>"
    echo ""
    echo "Example: $0 results/benchmark-20251119-120000/AcmeAir1.jtl"
    exit 1
fi

if [ ! -f "$JTL_FILE" ]; then
    echo "Error: Results file not found: $JTL_FILE"
    exit 1
fi

echo "================================================"
echo "JMeter Test Results Analysis"
echo "================================================"
echo "File: $JTL_FILE"
echo ""

# Count total requests
TOTAL=$(grep -c "httpSample" "$JTL_FILE")
SUCCESS=$(grep -c 's="true"' "$JTL_FILE")
FAILED=$(grep -c 's="false"' "$JTL_FILE")

echo "Overall Statistics:"
echo "-------------------"
echo "Total Requests: $TOTAL"
echo "Successful: $SUCCESS ($(echo "scale=2; $SUCCESS * 100 / $TOTAL" | bc)%)"
echo "Failed: $FAILED ($(echo "scale=2; $FAILED * 100 / $TOTAL" | bc)%)"
echo ""

# Response time statistics
echo "Response Time Statistics (ms):"
echo "------------------------------"
grep 'httpSample' "$JTL_FILE" | sed 's/.*t="\([^"]*\)".*/\1/' | awk '{
    sum+=$1
    if(NR==1){min=$1;max=$1}
    if($1<min){min=$1}
    if($1>max){max=$1}
    count++
}
END {
    print "Average: " sum/count " ms"
    print "Min: " min " ms"
    print "Max: " max " ms"
}'
echo ""

# Request breakdown by type
echo "Request Breakdown:"
echo "-------------------"
grep 'httpSample' "$JTL_FILE" | sed 's/.*lb="\([^"]*\)".*/\1/' | sort | uniq -c | sort -rn
echo ""

# Failed requests by type
if [ "$FAILED" -gt 0 ]; then
    echo "Failed Requests by Type:"
    echo "------------------------"
    grep 's="false"' "$JTL_FILE" | sed 's/.*lb="\([^"]*\)".*rc="\([^"]*\)".*/\2 - \1/' | sort | uniq -c | sort -rn
    echo ""
fi

# Throughput calculation
FIRST_TS=$(grep -m1 'httpSample' "$JTL_FILE" | sed 's/.*ts="\([^"]*\)".*/\1/')
LAST_TS=$(grep 'httpSample' "$JTL_FILE" | tail -1 | sed 's/.*ts="\([^"]*\)".*/\1/')
DURATION=$(echo "scale=2; ($LAST_TS - $FIRST_TS) / 1000" | bc)
THROUGHPUT=$(echo "scale=2; $TOTAL / $DURATION" | bc)

echo "Throughput:"
echo "-----------"
echo "Test Duration: $DURATION seconds"
echo "Throughput: $THROUGHPUT requests/second"
echo ""

echo "================================================"
echo "Analysis Complete"
echo "================================================"