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
	for _, node := range orchestrator.nodes {
		planStr, startTime := generateExecutionPlan() // or read from config
		plan := &pb.ExecutionPlan{
			NodeId:    node.NodeId,
			Plan:      planStr,
			StartTime: startTime,
		}
		ack, err := orchestrator.SendExecutionPlan(context.Background(), plan)
		log.Printf("Plan sent to %s: %v (err: %v)", node.NodeId, ack, err)
		// optionally: poll for logs after expected completion
	}

}
