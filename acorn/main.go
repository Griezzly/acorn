package main

import (
	pb "acorn/grpc"
	"acorn/pkg/logcollector"
	"context"
	"google.golang.org/grpc"
	"log"
	"net"
	"os"
)

func main() {

	orchestratorAddr := "10.0.1.10:50051" // Orchestrator private IP

	// Get hostname for node ID
	hostname, err := os.Hostname()
	if err != nil {
		log.Fatalf("Failed to get hostname: %v", err)
	}
	nodeID := hostname

	// Get the node's private IP address
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		log.Fatalf("Failed to get network interfaces: %v", err)
	}

	var nodeIP string
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				// Check if it's in the private network range (10.0.0.0/8)
				if ipnet.IP.To4()[0] == 10 {
					nodeIP = ipnet.IP.String()
					break
				}
			}
		}
	}

	if nodeIP == "" {
		log.Fatalf("Failed to find private IP address")
	}

	log.Printf("Starting benchmark node with ID: %s, IP: %s, connecting to: %s", nodeID, nodeIP, orchestratorAddr)

	// Set up connection to orchestrator as a client
	conn, err := grpc.Dial(orchestratorAddr, grpc.WithInsecure())
	if err != nil {
		log.Fatalf("Failed to connect to orchestrator: %v", err)
	}
	defer conn.Close()
	orchestratorClient := pb.NewBenchmarkOrchestratorClient(conn)

	// Register with orchestrator
	log.Printf("Registering node %s with orchestrator...", nodeID)
	_, err = orchestratorClient.RegisterNode(context.Background(), &pb.NodeInfo{
		NodeId: nodeID,
		Ip:     nodeIP,
		Specs:  "benchmark-node",
	})
	if err != nil {
		log.Fatalf("Failed to register with orchestrator: %v", err)
	}
	log.Printf("Successfully registered with orchestrator")

	lis, err := net.Listen("tcp", ":60051") // Listen on port for this node
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	logCollector := &logcollector.LogCollector{}
	executor := &PlanExecutor{
		logCollector:   logCollector,
		orchestratorIP: "10.0.1.10", // Oakestra orchestrator private IP
	}
	nodeID = hostname // Use hostname as node ID

	grpcServer := grpc.NewServer()
	pb.RegisterBenchmarkNodeServer(grpcServer, &server{
		orchestrator: orchestratorClient,
		logCollector: logCollector,
		executor:     executor,
		nodeID:       nodeID,
	})

	log.Println("BenchmarkNode gRPC server is listening on :60051")
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}

}
