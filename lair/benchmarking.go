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

	// Determine how many nodes will disconnect
	disconnectingCount := d.DisconnectingNodeAmount
	if disconnectingCount > len(nodeIPs) {
		disconnectingCount = len(nodeIPs)
	}
	if disconnectingCount <= 0 {
		return plans
	}

	// Randomly select which nodes will disconnect
	shuffledNodes := make([]string, len(nodeIPs))
	copy(shuffledNodes, nodeIPs)
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

		plans[nodeIP] = strings.Join(steps, "\n")
	}

	return plans
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

// ScenarioConfig holds configuration for creating benchmark scenarios
type ScenarioConfig struct {
	// Common settings
	ScenarioType string // "disconnect", "resource", "mixed", etc.
	Duration     int64  // in seconds

	// Disconnect scenario settings
	DisconnectNodeCount     int
	DisconnectDuration      int64
	FullDisconnect          bool
	DisconnectAmountPerNode int
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
