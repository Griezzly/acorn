package main

import (
	acorngrpc "acorn/grpc"
	"fmt"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/grpc"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

const httpPort = "2525"
const grpcPort = "2626"

var wg = &sync.WaitGroup{}

func main() {
	if err := run(); err != nil {
		log.Fatal("Fatal error, acorn terminating", err)
		os.Exit(1)
	}
	wg.Wait()
}

func run() error {
	log.SetFlags(log.LstdFlags | log.Lshortfile)

	errChan := make(chan error, 3)

	// run HTTP server in go routine
	wg.Add(1)
	go func() {
		defer wg.Done()
		mux := http.NewServeMux()

		log.Println("Starting HTTP server on port " + httpPort)

		mux.HandleFunc("/", httpHandler)

		mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		})
		mux.Handle("/metrics", promhttp.Handler())

		errChan <- http.ListenAndServe(":"+httpPort, mux)
	}()

	// run grpc server in go routine
	wg.Add(1)
	go func() {
		defer wg.Done()
		lis, err := net.Listen("tcp", ":"+grpcPort)
		if err != nil {
			log.Fatalf("failed to listen: %v", err)
			return
		}
		s := grpc.NewServer()
		acorngrpc.RegisterAcornServer(s, &grpcServer{})
		log.Printf("server listening at %v", lis.Addr())
		errChan <- s.Serve(lis)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		errChan <- fmt.Errorf("%s", <-c)
	}()

	log.Fatal("Acorn terminated ", <-errChan)
	return nil
}
