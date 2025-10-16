package main

import (
	"fmt"
	"log"
)

// InfraOutputs holds the infrastructure information
type InfraOutputs struct {
	OrchestratorPrivateIP string   `json:"orchestrator_private_ipv4"`
	WorkerPrivateIPs      []string `json:"worker_private_ipv4s"`
}

// GetInfraOutputs generates infrastructure details based on node count
// Worker nodes use predictable private IPs: 10.0.0.10, 10.0.0.11, 10.0.0.12, etc.
func GetInfraOutputs(nodeCount int) (*InfraOutputs, error) {
	if nodeCount < 1 {
		return nil, fmt.Errorf("node count must be at least 1, got: %d", nodeCount)
	}

	outputs := &InfraOutputs{
		OrchestratorPrivateIP: "10.0.1.10",
		WorkerPrivateIPs:      make([]string, 0, nodeCount),
	}

	// Generate worker IPs starting from 10.0.0.10
	for i := 0; i < nodeCount; i++ {
		workerIP := fmt.Sprintf("10.0.0.%d", 10+i)
		outputs.WorkerPrivateIPs = append(outputs.WorkerPrivateIPs, workerIP)
	}

	log.Printf("Generated infrastructure outputs for %d workers", len(outputs.WorkerPrivateIPs))
	return outputs, nil
}
