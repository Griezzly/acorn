package main

import (
	"fmt"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"log"
	"net/http"
)

const httpPort = "2525"

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
}
