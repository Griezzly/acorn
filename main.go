package main

import (
	acorngrpc "acorn/grpc"
	"fmt"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/grpc"
	"log"
	"net"
	"net/http"
)

const httpPort = "2525"
const grpcPort = "2626"

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)

	mux := http.NewServeMux()

	log.Println("Starting HTTP server on port " + httpPort)

	mux.HandleFunc("/", httpHandler)

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
	})
	mux.Handle("/metrics", promhttp.Handler())

	err := http.ListenAndServe(":"+httpPort, mux)
	if err != nil {
		fmt.Println("Server error:", err)
	}

	lis, err := net.Listen("tcp", grpcPort)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	s := grpc.NewServer()
	acorngrpc.RegisterAcornServer(s, &grpcServer{})
	log.Printf("server listening at %v", lis.Addr())
	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
