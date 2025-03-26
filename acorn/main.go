package main

import (
	"context"
	"log"
	"time"

	pb "acorn/grpc"
	"google.golang.org/grpc"
)

func main() {
	conn, err := grpc.Dial("localhost:50051", grpc.WithInsecure())
	if err != nil {
		log.Fatalf("Did not connect: %v", err)
	}
	defer conn.Close()
	c := pb.NewBenchmarkOrchestratorClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	// Register Node
	res, err := c.RegisterNode(ctx, &pb.NodeInfo{NodeId: "node-1", Ip: "192.168.1.2", Specs: "4vCPU, 8GB RAM"})
	if err != nil {
		log.Fatalf("Register failed: %v", err)
	}
	log.Printf("Registration response: %s", res.Status)

	// Send Execution Plan
	ack, err := c.SendExecutionPlan(ctx, &pb.ExecutionPlan{NodeId: "node-1", Plan: "crash, overload"})
	if err != nil {
		log.Fatalf("Plan failed: %v", err)
	}
	log.Printf("Plan ack: %s", ack.Status)

	// Collect Logs
	logs, err := c.CollectLogs(ctx, &pb.LogRequest{NodeId: "node-1"})
	if err != nil {
		log.Fatalf("Collect failed: %v", err)
	}
	log.Printf("Logs: %s", logs.Logs)
}
