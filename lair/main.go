package main

import (
	"context"
	"flag"
	"fmt"
	"google.golang.org/protobuf/types/known/emptypb"
	"log"
	"net"
	"os"
	"sync"
	"time"

	pb "acorn/grpc"
	"acorn/pkg/logcollector"
	"google.golang.org/grpc"
)

const targetNodeCount = 5 // Set this to how many nodes you want to wait for

// Command-line flags for benchmark configuration
var (
	scenarioType            = flag.String("scenario", "disconnect", "Benchmark scenario type (disconnect)")
	duration                = flag.Int64("duration", 60, "Benchmark duration in seconds")
	disconnectNodeCount     = flag.Int("disconnect-nodes", 1, "Number of nodes to disconnect (disconnect scenario)")
	disconnectDuration      = flag.Int64("disconnect-duration", 10, "Duration of each disconnect in seconds (disconnect scenario)")
	fullDisconnect          = flag.Bool("full-disconnect", true, "Full disconnect vs partial (disconnect scenario)")
	disconnectAmountPerNode = flag.Int("disconnect-amount", 1, "Number of disconnects per node (disconnect scenario)")
)

type orchestratorServer struct {
	pb.UnimplementedBenchmarkOrchestratorServer
	mu           sync.Mutex
	cond         *sync.Cond
	nodes        map[string]*pb.NodeInfo
	logCollector *logcollector.LogCollector
	startSignal  chan struct{}
	started      bool
}

func newOrchestratorServer(logCollector *logcollector.LogCollector) *orchestratorServer {
	server := &orchestratorServer{
		nodes:        make(map[string]*pb.NodeInfo),
		logCollector: logCollector,
		startSignal:  make(chan struct{}),
		started:      false,
	}
	server.cond = sync.NewCond(&server.mu)
	return server
}

func (s *orchestratorServer) RegisterNode(ctx context.Context, in *pb.NodeInfo) (*pb.RegisterResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	msg := fmt.Sprintf("Received node registration: %s at %s", in.NodeId, in.Ip)
	log.Println(msg)
	s.logCollector.Add(fmt.Sprintf("[NODE_REGISTER] %s", msg))
	s.nodes[in.NodeId] = in
	s.cond.Broadcast()
	return &pb.RegisterResponse{Status: "Registered"}, nil
}

func (s *orchestratorServer) CollectLogs(ctx context.Context, in *pb.LogRequest) (*pb.LogData, error) {
	log.Printf("Collecting logs from node %s", in.NodeId)
	return &pb.LogData{Logs: fmt.Sprintf("Sample logs for node %s", in.NodeId)}, nil
}

func (s *orchestratorServer) StartBenchmark(ctx context.Context, _ *emptypb.Empty) (*pb.ExecutionAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		msg := "Benchmark already started"
		log.Println(msg)
		s.logCollector.Add(fmt.Sprintf("[START_COMMAND_REJECTED] %s", msg))
		return &pb.ExecutionAck{Status: "Already started"}, nil
	}

	if len(s.nodes) < targetNodeCount {
		msg := fmt.Sprintf("Not enough nodes registered: %d/%d", len(s.nodes), targetNodeCount)
		log.Println(msg)
		s.logCollector.Add(fmt.Sprintf("[START_COMMAND_REJECTED] %s", msg))
		return &pb.ExecutionAck{Status: fmt.Sprintf("Not ready: %s", msg)}, fmt.Errorf("%s", msg)
	}

	s.started = true
	msg := "Benchmark start command received"
	log.Println(msg)
	s.logCollector.Add(fmt.Sprintf("[START_COMMAND_RECEIVED] %s", msg))
	close(s.startSignal)
	return &pb.ExecutionAck{Status: "Benchmark started"}, nil
}

func (s *orchestratorServer) SendExecutionPlan(ctx context.Context, plan *pb.ExecutionPlan) (*pb.ExecutionAck, error) {
	s.mu.Lock()
	node, ok := s.nodes[plan.NodeId]
	s.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("node %s not registered", plan.NodeId)
	}
	targetAddr := fmt.Sprintf("%s:60051", node.Ip)
	conn, err := grpc.Dial(targetAddr, grpc.WithInsecure())
	if err != nil {
		return nil, fmt.Errorf("failed to connect to node: %w", err)
	}
	defer conn.Close()
	client := pb.NewBenchmarkNodeClient(conn)
	return client.ReceivePlan(ctx, plan)
}

func (s *orchestratorServer) syncNodes() error {
	s.mu.Lock()
	nodesCopy := make(map[string]*pb.NodeInfo, len(s.nodes))
	for k, v := range s.nodes {
		nodesCopy[k] = v
	}
	s.mu.Unlock()

	var failed bool

	for nodeID, node := range nodesCopy {
		targetAddr := node.Ip + ":60051"
		conn, err := grpc.Dial(targetAddr, grpc.WithInsecure())
		if err != nil {
			msg := fmt.Sprintf("Failed to connect to node %s at %s: %v", nodeID, targetAddr, err)
			log.Println(msg)
			s.logCollector.Add(fmt.Sprintf("[SYNC_ERROR] %s", msg))
			failed = true
			continue
		}
		client := pb.NewBenchmarkNodeClient(conn)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		syncAck, err := client.SyncNode(ctx, &emptypb.Empty{})
		cancel()
		conn.Close()
		if err != nil {
			msg := fmt.Sprintf("Sync failed for node %s: %v, status: %v", nodeID, err, syncAck.GetStatus())
			log.Println(msg)
			s.logCollector.Add(fmt.Sprintf("[SYNC_ERROR] %s", msg))
			failed = true
			continue
		}
		msg := fmt.Sprintf("Node %s synced successfully", nodeID)
		log.Println(msg)
		s.logCollector.Add(fmt.Sprintf("[SYNC_SUCCESS] %s", msg))
	}
	if failed {
		return fmt.Errorf("one or more nodes failed to sync")
	}
	return nil
}

func main() {
	// Parse command-line flags
	flag.Parse()

	// Initialize log collector for orchestrator
	logCollector := &logcollector.LogCollector{}

	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	orchestrator := newOrchestratorServer(logCollector)

	grpcServer := grpc.NewServer()
	pb.RegisterBenchmarkOrchestratorServer(grpcServer, orchestrator)
	log.Println("Orchestrator server listening on :50051")
	logCollector.Add("[ORCHESTRATOR_START] Orchestrator server listening on :50051")

	// Start orchestrator server in a goroutine
	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			log.Fatalf("Failed to serve: %v", err)
		}
	}()

	// Wait until enough nodes are registered
	orchestrator.mu.Lock()
	for len(orchestrator.nodes) < targetNodeCount {
		msg := fmt.Sprintf("Waiting for %d nodes to register. Currently: %d", targetNodeCount, len(orchestrator.nodes))
		log.Println(msg)
		logCollector.Add(fmt.Sprintf("[NODE_REGISTRATION] %s", msg))
		orchestrator.cond.Wait()
	}
	orchestrator.mu.Unlock()
	log.Printf("All %d nodes registered!", targetNodeCount)
	logCollector.Add(fmt.Sprintf("[NODE_REGISTRATION_COMPLETE] All %d nodes registered. Waiting for start command...", targetNodeCount))

	// Wait for start signal
	log.Println("Ready to start benchmark. Send StartBenchmark gRPC call to begin.")
	<-orchestrator.startSignal
	log.Println("Start signal received! Beginning benchmark execution...")

	// SYNC phase
	logCollector.Add("[SYNC_START] Starting node synchronization")
	if err := orchestrator.syncNodes(); err != nil {
		msg := fmt.Sprintf("Sync failed: %v", err)
		log.Println(msg)
		logCollector.Add(fmt.Sprintf("[SYNC_FAILED] %s", msg))
		log.Fatalf("Sync failed: %v", err)
	}
	logCollector.Add("[SYNC_COMPLETE] All nodes synchronized successfully")

	// Create benchmark scenario based on command-line flags
	scenarioConfig := ScenarioConfig{
		ScenarioType:            *scenarioType,
		Duration:                *duration,
		DisconnectNodeCount:     *disconnectNodeCount,
		DisconnectDuration:      *disconnectDuration,
		FullDisconnect:          *fullDisconnect,
		DisconnectAmountPerNode: *disconnectAmountPerNode,
	}

	scenario, err := CreateScenario(scenarioConfig)
	if err != nil {
		log.Fatalf("Failed to create scenario: %v", err)
	}

	log.Printf("Using benchmark scenario: %s (duration: %ds)", scenario.GetName(), scenario.GetDuration())
	logCollector.Add(fmt.Sprintf("[SCENARIO_SELECTED] %s (duration: %ds)", scenario.GetName(), scenario.GetDuration()))

	// Collect node IPs for scenario generation
	var nodeIPs []string
	nodeIPToID := make(map[string]string)
	for nodeID, node := range orchestrator.nodes {
		nodeIPs = append(nodeIPs, node.Ip)
		nodeIPToID[node.Ip] = nodeID
	}

	// Generate execution plans using the scenario
	log.Println("Generating execution plans for all nodes...")
	logCollector.Add("[PLAN_GENERATION_START] Generating execution plans for all nodes")

	executionPlans := scenario.GenerateExecutionPlans(nodeIPs)
	startTime := time.Now().Add(5 * time.Second).UnixMilli() // start 5 seconds from now

	// Distribute plans to nodes
	for nodeIP, planStr := range executionPlans {
		nodeID := nodeIPToID[nodeIP]

		plan := &pb.ExecutionPlan{
			NodeId:    nodeID,
			Plan:      planStr,
			StartTime: startTime,
		}

		msg := fmt.Sprintf("Sending plan to node %s at %s (plan length: %d bytes)", nodeID, nodeIP, len(planStr))
		log.Println(msg)
		logCollector.Add(fmt.Sprintf("[PLAN_SEND] %s", msg))

		ack, err := orchestrator.SendExecutionPlan(context.Background(), plan)
		if err != nil {
			logCollector.Add(fmt.Sprintf("[PLAN_SEND_ERROR] Failed to send plan to %s: %v", nodeID, err))
		} else {
			logCollector.Add(fmt.Sprintf("[PLAN_SEND_SUCCESS] Plan sent to %s: %v", nodeID, ack))
		}
		log.Printf("Plan sent to %s: %v (err: %v)", nodeID, ack, err)
	}

	logCollector.Add("[ORCHESTRATION_COMPLETE] All plans distributed successfully")

	// Push orchestrator logs to Loki
	logs := logCollector.GetAndReset()
	lokiLabels := map[string]string{
		"job":     "benchmark_orchestrator",
		"node_id": "orchestrator",
	}

	// Use your Mac's Tailscale IP - get it with: tailscale ip -4
	// Or set via environment variable LOKI_URL
	lokiURL := os.Getenv("LOKI_URL")
	if lokiURL == "" {
		lokiURL = "http://100.77.231.113:3100/loki/api/v1/push" // Your Mac's Tailscale IP
	}

	pusher := logcollector.NewLokiPusher(lokiURL, lokiLabels)
	if err := pusher.Push(logs); err != nil {
		log.Printf("Failed to push orchestrator logs to Loki: %v", err)
	} else {
		log.Printf("Successfully pushed orchestrator logs to Loki (count: %d)", len(logs))
	}

	// Prevent main from exiting immediately
	select {}
}
