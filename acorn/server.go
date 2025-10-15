package main

import (
	pb "acorn/grpc"
	"acorn/pkg/logcollector"
	"context"
	"fmt"
	"google.golang.org/protobuf/types/known/emptypb"
	"log"
	"os"
	"os/exec"
	"sync"
)

// PlanStore safely holds the latest ExecutionPlan.
type PlanStore struct {
	mu   sync.RWMutex
	plan *pb.ExecutionPlan
}

// Save stores a copy of the received ExecutionPlan.
func (ps *PlanStore) Save(plan *pb.ExecutionPlan) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	// Deep copy is best; for demo, copy values directly (assume no pointers in ExecutionPlan)
	ps.plan = &pb.ExecutionPlan{
		NodeId:    plan.NodeId,
		Plan:      plan.Plan,
		StartTime: plan.StartTime,
	}
}

// Get retrieves a copy of the last stored ExecutionPlan, or nil if none stored.
func (ps *PlanStore) Get() *pb.ExecutionPlan {
	ps.mu.RLock()
	defer ps.mu.RUnlock()
	if ps.plan == nil {
		return nil
	}
	// Return a copy
	return &pb.ExecutionPlan{
		NodeId:    ps.plan.NodeId,
		Plan:      ps.plan.Plan,
		StartTime: ps.plan.StartTime,
	}
}

type server struct {
	pb.UnimplementedBenchmarkNodeServer // Embeds the unimplemented server for forward compatibility
	orchestrator                        pb.BenchmarkOrchestratorClient
	logCollector                        *logcollector.LogCollector
	executor                            *PlanExecutor
	nodeID                              string
}

// ReceivePlan handles receiving an execution plan.
func (s *server) ReceivePlan(ctx context.Context, plan *pb.ExecutionPlan) (*pb.ExecutionAck, error) {
	s.logCollector.Add(fmt.Sprintf("Received plan for node_id: %s", plan.NodeId))

	// Start execution in a separate goroutine
	go func(planCopy *pb.ExecutionPlan) {
		s.executor.Execute(planCopy)

		// After execution, push logs to Loki
		logs := s.logCollector.GetAndReset()

		lokiLabels := map[string]string{
			"job":     "benchmark_node",
			"node_id": planCopy.NodeId,
		}
		// Use your Mac's Tailscale IP - get it with: tailscale ip -4
		// Or set via environment variable LOKI_URL
		lokiURL := os.Getenv("LOKI_URL")
		if lokiURL == "" {
			lokiURL = "http://100.77.231.113:3100/loki/api/v1/push" // Your Mac's Tailscale IP
		}
		pusher := logcollector.NewLokiPusher(lokiURL, lokiLabels)
		if err := pusher.Push(logs); err != nil {
			log.Printf("Failed to push logs to Loki: %v", err)
		} else {
			log.Printf("Successfully pushed logs to Loki (count: %d)", len(logs))
		}

		// Optionally: also push to orchestrator if needed

		req := &pb.LogRequest{NodeId: s.nodeID}
		_, err := s.orchestrator.CollectLogs(context.Background(), req)
		if err != nil {
			log.Printf("failed to send logs to orchestrator: %v", err)
		} else {
			log.Printf("sent logs to orchestrator: \n%s", logs)
		}
	}(plan)

	return &pb.ExecutionAck{Status: "Execution started"}, nil

}

func (s *server) syncClock(ntpServer string) error {
	log.Printf("Syncing clock with NTP server: %s", ntpServer)
	cmd := exec.Command("sudo", "ntpdate", "-u", ntpServer)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to sync time: %v - %s", err, output)
	}
	log.Printf("NTP sync output: %s", output)
	return nil
}

// SyncNode handles synchronization.
func (s *server) SyncNode(ctx context.Context, _ *emptypb.Empty) (*pb.ExecutionAck, error) {
	s.logCollector.Add("SyncNode called")
	// Implement any synchronization logic if needed.
	if err := s.syncClock("pool.ntp.org"); err != nil {
		log.Printf("Warning: NTP sync failed: %v", err)
		return nil, err
	}

	return &pb.ExecutionAck{
		Status: "Node synchronized",
	}, nil
}
