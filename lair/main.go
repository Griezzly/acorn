package lair

import (
	"context"
	"fmt"
	"google.golang.org/protobuf/types/known/emptypb"
	"log"
	"net"
	"sync"
	"time"

	pb "acorn/grpc"
	"google.golang.org/grpc"
)

const targetNodeCount = 3 // Set this to how many nodes you want to wait for

type orchestratorServer struct {
	pb.UnimplementedBenchmarkOrchestratorServer
	mu    sync.Mutex
	cond  *sync.Cond
	nodes map[string]*pb.NodeInfo
}

func newOrchestratorServer() *orchestratorServer {
	server := &orchestratorServer{
		nodes: make(map[string]*pb.NodeInfo),
	}
	server.cond = sync.NewCond(&server.mu)
	return server
}

func (s *orchestratorServer) RegisterNode(ctx context.Context, in *pb.NodeInfo) (*pb.RegisterResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	log.Printf("Received node registration: %s at %s", in.NodeId, in.Ip)
	s.nodes[in.NodeId] = in
	return &pb.RegisterResponse{Status: "Registered"}, nil
}

func (s *orchestratorServer) CollectLogs(ctx context.Context, in *pb.LogRequest) (*pb.LogData, error) {
	log.Printf("Collecting logs from node %s", in.NodeId)
	return &pb.LogData{Logs: fmt.Sprintf("Sample logs for node %s", in.NodeId)}, nil
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
			log.Printf("Failed to connect to node %s at %s: %v", nodeID, targetAddr, err)
			failed = true
			continue
		}
		client := pb.NewBenchmarkNodeClient(conn)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		syncAck, err := client.SyncNode(ctx, &emptypb.Empty{})
		cancel()
		conn.Close()
		if err != nil || syncAck.GetStatus() != "OK" {
			log.Printf("Sync failed for node %s: %v, status: %v", nodeID, err, syncAck.GetStatus())
			failed = true
			continue
		}
		log.Printf("Node %s synced successfully", nodeID)
	}
	if failed {
		return fmt.Errorf("one or more nodes failed to sync")
	}
	return nil
}

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	orchestrator := newOrchestratorServer()

	grpcServer := grpc.NewServer()
	pb.RegisterBenchmarkOrchestratorServer(grpcServer, orchestrator)
	log.Println("Orchestrator server listening on :50051")

	// Start orchestrator server in a goroutine
	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			log.Fatalf("Failed to serve: %v", err)
		}
	}()

	// Wait until enough nodes are registered
	orchestrator.mu.Lock()
	for len(orchestrator.nodes) < targetNodeCount {
		log.Printf("Waiting for %d nodes to register. Currently: %d", targetNodeCount, len(orchestrator.nodes))
		orchestrator.cond.Wait()
	}
	orchestrator.mu.Unlock()
	log.Printf("All %d nodes registered!", targetNodeCount)

	// SYNC phase
	if err := orchestrator.syncNodes(); err != nil {
		log.Fatalf("Sync failed: %v", err)
	}

	for _, node := range orchestrator.nodes {
		nodeID := node.NodeId
		planStr, startTime := generateExecutionPlan() // or read from config
		plan := &pb.ExecutionPlan{
			NodeId:    node.NodeId,
			Plan:      planStr,
			StartTime: startTime,
		}
		ack, err := orchestrator.SendExecutionPlan(context.Background(), plan)
		log.Printf("Plan sent to %s: %v (err: %v)", nodeID, ack, err)
		// Optionally: collect logs after some time
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		logs, err := orchestrator.CollectLogs(ctx, &pb.LogRequest{NodeId: nodeID})
		if err != nil {
			log.Printf("CollectLogs failed for %s: %v", nodeID, err)
		} else {
			log.Printf("Logs from %s: %s", nodeID, logs.Logs)
		}
	}

	// Prevent main from exiting immediately
	select {}
}
