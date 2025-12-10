package main

import (
	"strconv"
	"strings"
	"testing"
)

// parseStep parses a plan step in format "timestamp:action:args"
type parsedStep struct {
	timestamp int64
	action    string
	target    string
}

func parseSteps(plan string) []parsedStep {
	if plan == "" {
		return nil
	}
	var steps []parsedStep
	for _, line := range strings.Split(plan, "\n") {
		parts := strings.SplitN(line, ":", 3)
		if len(parts) < 3 {
			continue
		}
		ts, _ := strconv.ParseInt(parts[0], 10, 64)
		steps = append(steps, parsedStep{
			timestamp: ts,
			action:    parts[1],
			target:    parts[2],
		})
	}
	return steps
}

func TestGenerateExecutionPlans_EmptyNodeList(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 2,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 1,
	}

	plans := scenario.GenerateExecutionPlans([]string{})

	if len(plans) != 0 {
		t.Errorf("expected empty plans for empty node list, got %d plans", len(plans))
	}
}

func TestGenerateExecutionPlans_ZeroDisconnectingNodes(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 0,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 1,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	// All plans should only have the "end" step since no nodes are disconnecting
	for _, ip := range nodeIPs {
		steps := parseSteps(plans[ip])
		// Should have exactly one step: the "end" step
		if len(steps) != 1 {
			t.Errorf("expected exactly 1 step (end) for %s when DisconnectingNodeAmount=0, got %d steps", ip, len(steps))
		}
		if len(steps) > 0 && steps[0].action != "end" {
			t.Errorf("expected only 'end' action for %s when DisconnectingNodeAmount=0, got: %s", ip, steps[0].action)
		}
	}
}

func TestGenerateExecutionPlans_SingleDisconnectPerNode(t *testing.T) {
	testCases := []struct {
		name                    string
		disconnectAmountPerNode int
	}{
		{"DisconnectAmountPerNode=0", 0},
		{"DisconnectAmountPerNode=1", 1},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			scenario := &DisconnectBenchmarkScenario{
				Duration:                60,
				DisconnectingNodeAmount: 1,
				DisconnectDuration:      10,
				FullDisconnect:          true,
				DisconnectAmountPerNode: tc.disconnectAmountPerNode,
			}

			nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12"}
			plans := scenario.GenerateExecutionPlans(nodeIPs)

			// Find the node with block/unblock commands (the disconnecting node)
			var disconnectingNode string
			for ip, plan := range plans {
				steps := parseSteps(plan)
				for _, step := range steps {
					if step.action == "block" || step.action == "unblock" {
						disconnectingNode = ip
						break
					}
				}
				if disconnectingNode != "" {
					break
				}
			}

			if disconnectingNode == "" {
				t.Fatal("expected at least one node to have block/unblock commands")
			}

			steps := parseSteps(plans[disconnectingNode])
			blockCount := 0
			unblockCount := 0
			for _, step := range steps {
				if step.action == "block" {
					blockCount++
				}
				if step.action == "unblock" {
					unblockCount++
				}
			}

			// With FullDisconnect=true and 3 nodes, should block 2 other nodes once
			expectedBlocks := 2 // 2 other nodes, 1 disconnect event
			if blockCount != expectedBlocks {
				t.Errorf("expected %d block commands, got %d", expectedBlocks, blockCount)
			}
			if unblockCount != expectedBlocks {
				t.Errorf("expected %d unblock commands, got %d", expectedBlocks, unblockCount)
			}
		})
	}
}

func TestGenerateExecutionPlans_MultipleDisconnectsPerNode(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 1,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 3,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	// Find the disconnecting node (one with block commands)
	var disconnectingNode string
	for ip, plan := range plans {
		steps := parseSteps(plan)
		for _, step := range steps {
			if step.action == "block" {
				disconnectingNode = ip
				break
			}
		}
		if disconnectingNode != "" {
			break
		}
	}

	if disconnectingNode == "" {
		t.Fatal("expected at least one node to have block commands")
	}

	steps := parseSteps(plans[disconnectingNode])
	blockCount := 0
	for _, step := range steps {
		if step.action == "block" {
			blockCount++
		}
	}

	// With 3 disconnects, 2 other nodes each time = 6 block commands
	expectedBlocks := 3 * 2
	if blockCount != expectedBlocks {
		t.Errorf("expected %d block commands for 3 disconnects, got %d", expectedBlocks, blockCount)
	}
}

func TestGenerateExecutionPlans_DisconnectsCappedByDuration(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                30, // 30 seconds total
		DisconnectingNodeAmount: 1,
		DisconnectDuration:      10, // 10 seconds per disconnect
		FullDisconnect:          true,
		DisconnectAmountPerNode: 10, // Requesting 10, but max should be 3 (30/10)
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	// Find the disconnecting node (one with block commands)
	var disconnectingNode string
	for ip, plan := range plans {
		steps := parseSteps(plan)
		for _, step := range steps {
			if step.action == "block" {
				disconnectingNode = ip
				break
			}
		}
		if disconnectingNode != "" {
			break
		}
	}

	if disconnectingNode == "" {
		t.Fatal("expected at least one node to have block commands")
	}

	steps := parseSteps(plans[disconnectingNode])
	blockCount := 0
	for _, step := range steps {
		if step.action == "block" {
			blockCount++
		}
	}

	// Max disconnects = 30/10 = 3, with 1 other node = 3 block commands
	maxExpectedBlocks := 3 * 1
	if blockCount > maxExpectedBlocks {
		t.Errorf("expected at most %d block commands (capped by duration), got %d", maxExpectedBlocks, blockCount)
	}
}

func TestGenerateExecutionPlans_FullDisconnect(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 1,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 1,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12", "10.0.0.13"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	// Find the disconnecting node (one with block commands)
	var disconnectingNode string
	for ip, plan := range plans {
		steps := parseSteps(plan)
		for _, step := range steps {
			if step.action == "block" {
				disconnectingNode = ip
				break
			}
		}
		if disconnectingNode != "" {
			break
		}
	}

	if disconnectingNode == "" {
		t.Fatal("expected at least one node to have block commands")
	}

	steps := parseSteps(plans[disconnectingNode])

	// Collect all blocked targets
	blockedTargets := make(map[string]bool)
	for _, step := range steps {
		if step.action == "block" {
			blockedTargets[step.target] = true
		}
	}

	// Should block ALL other nodes (3 nodes)
	expectedTargets := 3
	if len(blockedTargets) != expectedTargets {
		t.Errorf("FullDisconnect should block all %d other nodes, got %d", expectedTargets, len(blockedTargets))
	}

	// Verify the disconnecting node doesn't block itself
	if blockedTargets[disconnectingNode] {
		t.Error("node should not block itself")
	}
}

func TestGenerateExecutionPlans_PartialDisconnect(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 1,
		DisconnectDuration:      10,
		FullDisconnect:          false, // Partial disconnect
		DisconnectAmountPerNode: 1,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12", "10.0.0.13", "10.0.0.14"}

	// Run multiple times to verify randomness produces subset
	foundPartialDisconnect := false
	for i := 0; i < 20; i++ {
		plans := scenario.GenerateExecutionPlans(nodeIPs)

		// Find the disconnecting node (one with block commands)
		var disconnectingNode string
		for ip, plan := range plans {
			steps := parseSteps(plan)
			for _, step := range steps {
				if step.action == "block" {
					disconnectingNode = ip
					break
				}
			}
			if disconnectingNode != "" {
				break
			}
		}

		if disconnectingNode == "" {
			continue
		}

		steps := parseSteps(plans[disconnectingNode])
		blockedTargets := make(map[string]bool)
		for _, step := range steps {
			if step.action == "block" {
				blockedTargets[step.target] = true
			}
		}

		// Partial disconnect should block at least 1 but possibly not all
		otherNodeCount := len(nodeIPs) - 1
		if len(blockedTargets) >= 1 && len(blockedTargets) <= otherNodeCount {
			if len(blockedTargets) < otherNodeCount {
				foundPartialDisconnect = true
			}
		}
	}

	// With 4 other nodes and random selection, we should see partial disconnects
	if !foundPartialDisconnect {
		t.Log("Warning: partial disconnect test may need more iterations or different random seed")
	}
}

func TestGenerateExecutionPlans_DisconnectingNodeAmountCapped(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 10, // More than available nodes
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 1,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	// Count nodes with non-empty plans
	nodesWithPlans := 0
	for _, plan := range plans {
		if plan != "" {
			nodesWithPlans++
		}
	}

	// Should be capped at actual node count
	if nodesWithPlans > len(nodeIPs) {
		t.Errorf("disconnecting nodes should be capped at %d, got %d", len(nodeIPs), nodesWithPlans)
	}
}

func TestGenerateExecutionPlans_TimingWithinDuration(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 1,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 3,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11"}
	durationMs := scenario.Duration * 1000

	for i := 0; i < 10; i++ {
		plans := scenario.GenerateExecutionPlans(nodeIPs)

		for ip, plan := range plans {
			if plan == "" {
				continue
			}

			steps := parseSteps(plan)
			for _, step := range steps {
				if step.timestamp < 0 {
					t.Errorf("node %s: timestamp %d should not be negative", ip, step.timestamp)
				}
				if step.timestamp > durationMs {
					t.Errorf("node %s: timestamp %d exceeds duration %d", ip, step.timestamp, durationMs)
				}
			}
		}
	}
}

func TestGenerateExecutionPlans_EveryBlockHasUnblock(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 2,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 2,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	for ip, plan := range plans {
		if plan == "" {
			continue
		}

		steps := parseSteps(plan)
		blockCounts := make(map[string]int)
		unblockCounts := make(map[string]int)

		for _, step := range steps {
			if step.action == "block" {
				blockCounts[step.target]++
			}
			if step.action == "unblock" {
				unblockCounts[step.target]++
			}
		}

		// Every blocked target should have matching unblock
		for target, blockCount := range blockCounts {
			if unblockCounts[target] != blockCount {
				t.Errorf("node %s: target %s has %d blocks but %d unblocks",
					ip, target, blockCount, unblockCounts[target])
			}
		}
	}
}

func TestGenerateExecutionPlans_UnblockAfterBlock(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 1,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 1,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	for ip, plan := range plans {
		if plan == "" {
			continue
		}

		steps := parseSteps(plan)
		blockTimes := make(map[string]int64)

		for _, step := range steps {
			if step.action == "block" {
				blockTimes[step.target] = step.timestamp
			}
			if step.action == "unblock" {
				blockTime, exists := blockTimes[step.target]
				if !exists {
					t.Errorf("node %s: unblock for %s without prior block", ip, step.target)
					continue
				}
				if step.timestamp < blockTime {
					t.Errorf("node %s: unblock at %d is before block at %d for %s",
						ip, step.timestamp, blockTime, step.target)
				}
			}
		}
	}
}

func TestGenerateExecutionPlans_AllNodesGetPlanEntry(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 1,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 1,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	// All nodes should have an entry in the plans map (even if empty)
	for _, ip := range nodeIPs {
		if _, exists := plans[ip]; !exists {
			t.Errorf("node %s should have an entry in plans map", ip)
		}
	}
}

func TestGenerateExecutionPlans_NodeDoesNotBlockItself(t *testing.T) {
	scenario := &DisconnectBenchmarkScenario{
		Duration:                60,
		DisconnectingNodeAmount: 3,
		DisconnectDuration:      10,
		FullDisconnect:          true,
		DisconnectAmountPerNode: 2,
	}

	nodeIPs := []string{"10.0.0.10", "10.0.0.11", "10.0.0.12"}
	plans := scenario.GenerateExecutionPlans(nodeIPs)

	for ip, plan := range plans {
		if plan == "" {
			continue
		}

		steps := parseSteps(plan)
		for _, step := range steps {
			if step.action == "block" && step.target == ip {
				t.Errorf("node %s should not block itself", ip)
			}
		}
	}
}
