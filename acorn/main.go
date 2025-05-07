package acorn

import (
	pb "acorn/grpc"
	"google.golang.org/grpc"
	"log"
	"net"
)

func main() {

	orchestratorAddr := "orchestrator:50051" // Use actual orchestrator address/port

	// Set up connection to orchestrator as a client
	conn, err := grpc.Dial(orchestratorAddr, grpc.WithInsecure())
	if err != nil {
		log.Fatalf("Failed to connect to orchestrator: %v", err)
	}
	defer conn.Close()
	orchestratorClient := pb.NewBenchmarkOrchestratorClient(conn)

	lis, err := net.Listen("tcp", ":60051") // Listen on port for this node
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	logCollector := &LogCollector{}
	executor := &PlanExecutor{logCollector: logCollector}
	nodeID := "your_node_id" // set appropriately

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
