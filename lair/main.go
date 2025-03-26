package lair

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"

	pb "acorn/grpc"
	"google.golang.org/grpc"
)

type orchestratorServer struct {
	pb.UnimplementedBenchmarkOrchestratorServer
	mu    sync.Mutex
	nodes map[string]*pb.NodeInfo
}

func (s *orchestratorServer) RegisterNode(ctx context.Context, in *pb.NodeInfo) (*pb.RegisterResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	log.Printf("Received node registration: %s at %s", in.NodeId, in.Ip)
	s.nodes[in.NodeId] = in
	return &pb.RegisterResponse{Status: "Registered"}, nil
}

func (s *orchestratorServer) SendExecutionPlan(ctx context.Context, in *pb.ExecutionPlan) (*pb.ExecutionAck, error) {
	log.Printf("Sending plan to node %s: %s", in.NodeId, in.Plan)
	return &pb.ExecutionAck{Status: "Plan Received"}, nil
}

func (s *orchestratorServer) CollectLogs(ctx context.Context, in *pb.LogRequest) (*pb.LogData, error) {
	log.Printf("Collecting logs from node %s", in.NodeId)
	return &pb.LogData{Logs: fmt.Sprintf("Sample logs for node %s", in.NodeId)}, nil
}

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	s := grpc.NewServer()
	orchestrator := &orchestratorServer{
		nodes: make(map[string]*pb.NodeInfo),
	}
	pb.RegisterBenchmarkOrchestratorServer(s, orchestrator)
	log.Println("Orchestrator server listening on :50051")
	if err := s.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}
