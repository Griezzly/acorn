package main

import (
	"fmt"
	"log"
	"math/rand"
	"os/exec"
	"strings"
	"time"
)

// BenchmarkScenario represents a benchmarking scenario that can generate execution plans for nodes
type BenchmarkScenario interface {
	// GenerateExecutionPlans creates execution plans for each node
	GenerateExecutionPlans(nodeIPs []string) map[string]string
	// GetDuration returns the total duration of the benchmark in seconds
	GetDuration() int64
	// GetName returns the human-readable name of the scenario
	GetName() string
}

// DisconnectBenchmarkScenario defines the configuration for benchmarking network disconnection scenarios.
// It specifies the total duration, number of nodes to disconnect, and the duration of disconnection in seconds.
// If FullDisconnect is true, nodes will be completely disconnected from all other nodes otherwise will only disconnect from a subset.
type DisconnectBenchmarkScenario struct {
	Duration                int64 // in seconds
	DisconnectingNodeAmount int
	DisconnectDuration      int64 // in seconds
	FullDisconnect          bool
	DisconnectAmountPerNode int
	ExcludedNodeIPs         []string
}

// GenerateExecutionPlans creates execution plans for each node based on the disconnect benchmark scenario.
// nodeIPs: list of IPs of the nodes participating in the benchmark
// Returns a map of nodeIP -> execution plan string
func (d *DisconnectBenchmarkScenario) GenerateExecutionPlans(nodeIPs []string) map[string]string {
	plans := make(map[string]string)

	if len(nodeIPs) == 0 {
		return plans
	}

	// Initialize empty plans for all nodes
	for _, ip := range nodeIPs {
		plans[ip] = ""
	}

	// Filter out excluded nodes from being selected for disconnection
	eligibleNodes := make([]string, 0, len(nodeIPs))
	for _, ip := range nodeIPs {
		if !d.isNodeExcluded(ip) {
			eligibleNodes = append(eligibleNodes, ip)
		}
	}

	log.Printf("Total nodes: %d, Eligible for disconnection: %d, Excluded: %d",
		len(nodeIPs), len(eligibleNodes), len(nodeIPs)-len(eligibleNodes))

	// If no eligible nodes, return empty plans
	if len(eligibleNodes) == 0 {
		log.Printf("No eligible nodes for disconnection (all excluded)")
		return plans
	}

	// Determine how many nodes will disconnect
	disconnectingCount := d.DisconnectingNodeAmount
	if disconnectingCount > len(eligibleNodes) {
		disconnectingCount = len(eligibleNodes)
	}
	if disconnectingCount <= 0 {
		// Even if no nodes are disconnecting, add end step to all nodes
		durationMs := d.Duration * 1000
		for nodeIP := range plans {
			endTimestamp := durationMs
			plans[nodeIP] = fmt.Sprintf("%d:end:benchmark_complete", endTimestamp)
		}
		return plans
	}

	// Randomly select which nodes will disconnect (from eligible nodes only)
	shuffledNodes := make([]string, len(eligibleNodes))
	copy(shuffledNodes, eligibleNodes)
	rand.Shuffle(len(shuffledNodes), func(i, j int) {
		shuffledNodes[i], shuffledNodes[j] = shuffledNodes[j], shuffledNodes[i]
	})
	disconnectingNodes := shuffledNodes[:disconnectingCount]

	// Calculate how many times each node will disconnect
	disconnectsPerNode := d.DisconnectAmountPerNode
	if disconnectsPerNode <= 1 {
		disconnectsPerNode = 1
	}

	// Cap disconnects at duration/disconnectDuration to ensure all disconnects fit
	if d.DisconnectDuration > 0 {
		maxDisconnects := int(d.Duration / d.DisconnectDuration)
		if maxDisconnects < 1 {
			maxDisconnects = 1
		}
		if disconnectsPerNode > maxDisconnects {
			disconnectsPerNode = maxDisconnects
		}
	}

	durationMs := d.Duration * 1000
	disconnectDurationMs := d.DisconnectDuration * 1000

	// Generate plan for each disconnecting node
	for _, nodeIP := range disconnectingNodes {
		var steps []string

		// Get other nodes (potential targets for partial disconnect)
		otherNodes := make([]string, 0, len(nodeIPs)-1)
		for _, ip := range nodeIPs {
			if ip != nodeIP {
				otherNodes = append(otherNodes, ip)
			}
		}

		// Generate random disconnect events for this node
		for i := 0; i < disconnectsPerNode; i++ {
			// Calculate the time window for this disconnect event
			// Ensure disconnects don't overlap and fit within duration
			windowSize := durationMs / int64(disconnectsPerNode)
			windowStart := int64(i) * windowSize
			windowEnd := windowStart + windowSize - disconnectDurationMs

			if windowEnd <= windowStart {
				windowEnd = windowStart + 1000 // At least 1 second window
			}

			// Random start time within the window
			disconnectStart := windowStart + rand.Int63n(windowEnd-windowStart+1)
			reconnectTime := disconnectStart + disconnectDurationMs

			// Ensure reconnect happens before benchmark ends
			if reconnectTime > durationMs {
				reconnectTime = durationMs
			}

			var targetIPs []string
			if d.FullDisconnect {
				// Full disconnect: block all other nodes
				targetIPs = otherNodes
			} else {
				// Partial disconnect: block a random subset of other nodes
				if len(otherNodes) > 0 {
					// Select random subset (1 to len(otherNodes))
					subsetSize := rand.Intn(len(otherNodes)) + 1
					shuffledOthers := make([]string, len(otherNodes))
					copy(shuffledOthers, otherNodes)
					rand.Shuffle(len(shuffledOthers), func(i, j int) {
						shuffledOthers[i], shuffledOthers[j] = shuffledOthers[j], shuffledOthers[i]
					})
					targetIPs = shuffledOthers[:subsetSize]
				}
			}

			// Generate block and unblock steps for each target
			for _, targetIP := range targetIPs {
				steps = append(steps, fmt.Sprintf("%d:block:%s", disconnectStart, targetIP))
				steps = append(steps, fmt.Sprintf("%d:unblock:%s", reconnectTime, targetIP))
			}
		}

		// Add explicit end step at the benchmark duration
		endTimestamp := durationMs
		steps = append(steps, fmt.Sprintf("%d:end:benchmark_complete", endTimestamp))

		plans[nodeIP] = strings.Join(steps, "\n")
	}

	// For nodes that don't disconnect, still add an end step
	for nodeIP, plan := range plans {
		if plan == "" {
			endTimestamp := durationMs
			plans[nodeIP] = fmt.Sprintf("%d:end:benchmark_complete", endTimestamp)
		}
	}

	return plans
}

// isNodeExcluded checks if a node IP is in the excluded list
func (d *DisconnectBenchmarkScenario) isNodeExcluded(nodeIP string) bool {
	for _, excludedIP := range d.ExcludedNodeIPs {
		if nodeIP == excludedIP {
			return true
		}
	}
	return false
}

// GetDuration returns the total duration of the benchmark in seconds
func (d *DisconnectBenchmarkScenario) GetDuration() int64 {
	return d.Duration
}

// GetName returns the human-readable name of the scenario
func (d *DisconnectBenchmarkScenario) GetName() string {
	if d.FullDisconnect {
		return "Network Partition (Full Disconnect)"
	}
	return "Network Partition (Partial Disconnect)"
}

// NodeFailureBenchmarkScenario defines the configuration for benchmarking node failure scenarios.
// It specifies the total duration, number of nodes to fail, and the duration of failure in seconds.
// This simulates complete node failures by stopping and restarting NodeEngine.
type NodeFailureBenchmarkScenario struct {
	Duration             int64 // in seconds
	FailingNodeAmount    int
	FailureDuration      int64 // in seconds
	FailureAmountPerNode int
	ExcludedNodeIPs      []string
}

// GenerateExecutionPlans creates execution plans for each node based on the node failure benchmark scenario.
// nodeIPs: list of IPs of the nodes participating in the benchmark
// Returns a map of nodeIP -> execution plan string
func (n *NodeFailureBenchmarkScenario) GenerateExecutionPlans(nodeIPs []string) map[string]string {
	plans := make(map[string]string)

	if len(nodeIPs) == 0 {
		return plans
	}

	// Initialize empty plans for all nodes
	for _, ip := range nodeIPs {
		plans[ip] = ""
	}

	// Filter out excluded nodes from being selected for failure
	eligibleNodes := make([]string, 0, len(nodeIPs))
	for _, ip := range nodeIPs {
		if !n.isNodeExcluded(ip) {
			eligibleNodes = append(eligibleNodes, ip)
		}
	}

	log.Printf("Total nodes: %d, Eligible for failure: %d, Excluded: %d",
		len(nodeIPs), len(eligibleNodes), len(nodeIPs)-len(eligibleNodes))

	// If no eligible nodes, return empty plans
	if len(eligibleNodes) == 0 {
		log.Printf("No eligible nodes for failure (all excluded)")
		return plans
	}

	// Determine how many nodes will fail
	failingCount := n.FailingNodeAmount
	if failingCount > len(eligibleNodes) {
		failingCount = len(eligibleNodes)
	}
	if failingCount <= 0 {
		// Even if no nodes are failing, add end step to all nodes
		durationMs := n.Duration * 1000
		for nodeIP := range plans {
			endTimestamp := durationMs
			plans[nodeIP] = fmt.Sprintf("%d:end:benchmark_complete", endTimestamp)
		}
		return plans
	}

	// Randomly select which nodes will fail (from eligible nodes only)
	shuffledNodes := make([]string, len(eligibleNodes))
	copy(shuffledNodes, eligibleNodes)
	rand.Shuffle(len(shuffledNodes), func(i, j int) {
		shuffledNodes[i], shuffledNodes[j] = shuffledNodes[j], shuffledNodes[i]
	})
	failingNodes := shuffledNodes[:failingCount]

	// Calculate how many times each node will fail
	failuresPerNode := n.FailureAmountPerNode
	if failuresPerNode <= 1 {
		failuresPerNode = 1
	}

	// Cap failures at duration/failureDuration to ensure all failures fit
	if n.FailureDuration > 0 {
		maxFailures := int(n.Duration / n.FailureDuration)
		if maxFailures < 1 {
			maxFailures = 1
		}
		if failuresPerNode > maxFailures {
			failuresPerNode = maxFailures
		}
	}

	durationMs := n.Duration * 1000
	failureDurationMs := n.FailureDuration * 1000

	// Generate plan for each failing node
	for _, nodeIP := range failingNodes {
		var steps []string

		// Generate random failure events for this node
		for i := 0; i < failuresPerNode; i++ {
			// Calculate the time window for this failure event
			// Ensure failures don't overlap and fit within duration
			windowSize := durationMs / int64(failuresPerNode)
			windowStart := int64(i) * windowSize
			windowEnd := windowStart + windowSize - failureDurationMs

			if windowEnd <= windowStart {
				windowEnd = windowStart + 1000 // At least 1 second window
			}

			// Random start time within the window
			failureStart := windowStart + rand.Int63n(windowEnd-windowStart+1)
			recoveryTime := failureStart + failureDurationMs

			// Ensure recovery happens before benchmark ends
			if recoveryTime > durationMs {
				recoveryTime = durationMs
			}

			// Generate node-stop and node-start steps
			steps = append(steps, fmt.Sprintf("%d:node-stop:", failureStart))
			steps = append(steps, fmt.Sprintf("%d:node-start:", recoveryTime))
		}

		// Add explicit end step at the benchmark duration
		endTimestamp := durationMs
		steps = append(steps, fmt.Sprintf("%d:end:benchmark_complete", endTimestamp))

		plans[nodeIP] = strings.Join(steps, "\n")
	}

	// For nodes that don't fail, still add an end step
	for nodeIP, plan := range plans {
		if plan == "" {
			endTimestamp := durationMs
			plans[nodeIP] = fmt.Sprintf("%d:end:benchmark_complete", endTimestamp)
		}
	}

	return plans
}

// isNodeExcluded checks if a node IP is in the excluded list
func (n *NodeFailureBenchmarkScenario) isNodeExcluded(nodeIP string) bool {
	for _, excludedIP := range n.ExcludedNodeIPs {
		if nodeIP == excludedIP {
			return true
		}
	}
	return false
}

// GetDuration returns the total duration of the benchmark in seconds
func (n *NodeFailureBenchmarkScenario) GetDuration() int64 {
	return n.Duration
}

// GetName returns the human-readable name of the scenario
func (n *NodeFailureBenchmarkScenario) GetName() string {
	return "Node Failure (NodeEngine Stop/Start)"
}

// ScenarioConfig holds configuration for creating benchmark scenarios
type ScenarioConfig struct {
	// Common settings
	ScenarioType string // "disconnect", "node-failure", "resource", "mixed", etc.
	Duration     int64  // in seconds

	// Disconnect scenario settings
	DisconnectNodeCount     int
	DisconnectDuration      int64
	FullDisconnect          bool
	DisconnectAmountPerNode int
	ExcludedNodeIPs         []string

	// Node failure scenario settings
	FailureNodeCount     int
	FailureDuration      int64
	FailureAmountPerNode int
}

// CreateScenario creates a benchmark scenario based on the configuration
func CreateScenario(config ScenarioConfig) (BenchmarkScenario, error) {
	switch config.ScenarioType {
	case "disconnect":
		return &DisconnectBenchmarkScenario{
			Duration:                config.Duration,
			DisconnectingNodeAmount: config.DisconnectNodeCount,
			DisconnectDuration:      config.DisconnectDuration,
			FullDisconnect:          config.FullDisconnect,
			DisconnectAmountPerNode: config.DisconnectAmountPerNode,
			ExcludedNodeIPs:         config.ExcludedNodeIPs,
		}, nil
	case "node-failure":
		return &NodeFailureBenchmarkScenario{
			Duration:             config.Duration,
			FailingNodeAmount:    config.FailureNodeCount,
			FailureDuration:      config.FailureDuration,
			FailureAmountPerNode: config.FailureAmountPerNode,
			ExcludedNodeIPs:      config.ExcludedNodeIPs,
		}, nil
	default:
		return nil, fmt.Errorf("unknown scenario type: %s", config.ScenarioType)
	}
}

func syncClock(ntpServer string) error {
	log.Printf("Syncing clock with NTP server: %s", ntpServer)
	cmd := exec.Command("sudo", "ntpdate", "-u", ntpServer)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to sync time: %v - %s", err, output)
	}
	log.Printf("NTP sync output: %s", output)
	return nil
}

// generateSimpleExecutionPlanForNode creates a simple chaos engineering plan for a benchmark node.
// nodeIP: the IP of the node that will execute this plan
// targetIPs: IPs of other nodes/services that can be targeted for network chaos
func generateSimpleExecutionPlanForNode(nodeIP string, targetIPs []string) (string, int64) {
	var steps []string

	// Basic plan: introduce some network chaos and resource constraints
	// Targeting first available service if targetIPs exist
	if len(targetIPs) > 0 {
		steps = append(steps, fmt.Sprintf("1000:block:%s", targetIPs[0]))
		steps = append(steps, fmt.Sprintf("6000:unblock:%s", targetIPs[0]))
	}

	// Network delays and packet loss
	steps = append(steps, "2000:delay:150")
	steps = append(steps, "3000:loss:10")

	// Resource constraints
	steps = append(steps, "4000:mem:512")
	steps = append(steps, "5000:cpu:0.6")

	plan := strings.Join(steps, "\n")
	start := time.Now().Add(5 * time.Second).UnixMilli() // start 5 seconds from now
	return plan, start
}
