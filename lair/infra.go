package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
)

// TerraformOutputs holds the infrastructure information from Terraform
type TerraformOutputs struct {
	OrchestratorPublicIP  string            `json:"orchestrator_public_ipv4"`
	OrchestratorPrivateIP string            `json:"orchestrator_private_ipv4"`
	WorkerPublicIPs       []string          `json:"worker_public_ipv4s"`
	WorkerPrivateIPs      []string          `json:"worker_private_ipv4s"`
	WorkersInfo           map[string]Worker `json:"workers_info"`
}

type Worker struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	PublicIP  string `json:"public_ip"`
	PrivateIP string `json:"private_ip"`
	WorkerID  int    `json:"worker_id"`
}

// GetTerraformOutputs executes terraform output to get infrastructure details
func GetTerraformOutputs(terraformDir string) (*TerraformOutputs, error) {
	if terraformDir == "" {
		// Default to ../terraform relative to the project root
		cwd, err := os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("failed to get working directory: %w", err)
		}
		terraformDir = filepath.Join(cwd, "..", "terraform")
	}

	// Check if terraform directory exists
	if _, err := os.Stat(terraformDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("terraform directory not found: %s", terraformDir)
	}

	outputs := &TerraformOutputs{}

	// Get each output value using terraform output -json
	cmd := exec.Command("terraform", "output", "-json")
	cmd.Dir = terraformDir
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to run terraform output: %w", err)
	}

	// Parse the full JSON output
	var rawOutputs map[string]struct {
		Value json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(output, &rawOutputs); err != nil {
		return nil, fmt.Errorf("failed to parse terraform output: %w", err)
	}

	// Extract individual values
	if val, ok := rawOutputs["orchestrator_public_ipv4"]; ok {
		json.Unmarshal(val.Value, &outputs.OrchestratorPublicIP)
	}
	if val, ok := rawOutputs["orchestrator_private_ipv4"]; ok {
		json.Unmarshal(val.Value, &outputs.OrchestratorPrivateIP)
	}
	if val, ok := rawOutputs["worker_public_ipv4s"]; ok {
		json.Unmarshal(val.Value, &outputs.WorkerPublicIPs)
	}
	if val, ok := rawOutputs["worker_private_ipv4s"]; ok {
		json.Unmarshal(val.Value, &outputs.WorkerPrivateIPs)
	}
	if val, ok := rawOutputs["workers_info"]; ok {
		json.Unmarshal(val.Value, &outputs.WorkersInfo)
	}

	log.Printf("Loaded Terraform outputs: %d workers", len(outputs.WorkerPrivateIPs))
	return outputs, nil
}
