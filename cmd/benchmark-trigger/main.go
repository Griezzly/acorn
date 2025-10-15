package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"time"

	pb "acorn/grpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

func main() {
	// Parse command-line flags
	serverAddr := flag.String("server", "localhost:50051", "Orchestrator server address (host:port)")
	timeout := flag.Int("timeout", 30, "Connection timeout in seconds")
	flag.Parse()

	log.Printf("Connecting to orchestrator at %s...", *serverAddr)

	// Set up connection to the orchestrator
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*timeout)*time.Second)
	defer cancel()

	conn, err := grpc.DialContext(ctx, *serverAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
	if err != nil {
		log.Fatalf("Failed to connect to orchestrator: %v", err)
	}
	defer conn.Close()

	log.Printf("Connected successfully!")

	// Create client
	client := pb.NewBenchmarkOrchestratorClient(conn)

	// Send StartBenchmark request
	log.Printf("Sending StartBenchmark request...")

	startCtx, startCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer startCancel()

	ack, err := client.StartBenchmark(startCtx, &emptypb.Empty{})
	if err != nil {
		log.Fatalf("Failed to start benchmark: %v", err)
	}

	// Print acknowledgment
	fmt.Printf("\n✓ Benchmark started successfully!\n")
	fmt.Printf("Status: %s\n", ack.GetStatus())

	log.Printf("Benchmark execution initiated.")
}
