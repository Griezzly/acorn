package main

import (
	"acorn/grpc"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"runtime"
	"sync"
	"time"
)

type Request struct {
	RequestTime int  `json:"requestTime"` // ms
	PayloadSize int  `json:"payloadSize"` // bytes
	Timeout     bool `json:"timeout"`
	Fail        bool `json:"fail"`
	LoadCPU     int  `json:"loadCPU"`
}

type ReponseError struct {
	msg string
}

func (e ReponseError) Error() string {
	return e.msg
}

type Response struct {
	Hash    string    `json:"hash"`
	Payload []byte    `json:"payload"`
	Start   time.Time `json:"start"`
	End     time.Time `json:"end"`
	Err     error     `json:"error"`
}

func computeHash(p Request, t time.Time) string {
	dataToHash := []byte(string(p.RequestTime) + string(p.PayloadSize) + t.String())
	hash := sha256.New()
	hash.Write(dataToHash)
	hashBytes := hash.Sum(nil)
	return hex.EncodeToString(hashBytes)
}

func generateRandomBytes(numBytes int) ([]byte, error) {
	randomBytes := make([]byte, numBytes)
	_, err := rand.Read(randomBytes)
	if err != nil {
		return nil, err
	}
	return randomBytes, nil
}

var (
	stopCh    = make(chan struct{})
	stopped   = make(chan struct{})
	closeOnce sync.Once
	cpuLoaded bool
	stopFlag  bool
)

func loadCpu(percentage float64) {
	numCPU := runtime.NumCPU()
	totalLoad := int(percentage)
	partialLoad := percentage - float64(totalLoad)
	var wg sync.WaitGroup

	for i := 0; i < numCPU; i++ {
		coreLoad := totalLoad / numCPU
		if i < int(partialLoad*float64(numCPU)) {
			coreLoad++
		}

		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stopCh:
					return
				default:
					start := time.Now()

					for time.Since(start).Seconds() < float64(coreLoad)/100.0 {
						// Busy-wait to simulate CPU load
					}

					time.Sleep(time.Duration(100-coreLoad) * time.Millisecond)
				}
			}
		}()
	}

	wg.Wait()
}

func unloadCPU() {
	closeOnce.Do(func() {
		close(stopCh)
	})
}

func handleRequest(request Request) Response {
	begin := time.Now()
	requestHash := computeHash(request, begin)
	log.Println(requestHash + " - request received")
	if request.LoadCPU > 0 {
		go loadCpu(float64(request.LoadCPU))
		cpuLoaded = true
	}
	if cpuLoaded && request.LoadCPU == 0 {
		unloadCPU()
		cpuLoaded = false
	}
	time.Sleep(time.Duration(request.RequestTime) * time.Millisecond)
	if request.Fail {
		return Response{Hash: requestHash, Err: ReponseError{"forced failure"}}
	}

	payload, err := generateRandomBytes(request.PayloadSize)
	if err != nil {
		return Response{Hash: requestHash, Err: err}
	}

	return Response{Hash: requestHash, Payload: payload, Start: begin, End: time.Now()}
}

func httpHandler(w http.ResponseWriter, r *http.Request) {
	var request Request

	err := json.NewDecoder(r.Body).Decode(&request)

	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var timeout time.Duration = 0

	if request.Timeout {
		timeout = 60 * time.Second
	}

	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	select {
	case <-time.After(timeout):
		// Simulate timeout by waiting for the timeout duration
		log.Println("Request timed out")
	case <-ctx.Done():
		if !request.Timeout {
			response := handleRequest(request)
			b, err := json.Marshal(response)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}

			w.Write(b)
			if response.Err != nil {
				http.Error(w, response.Err.Error(), http.StatusInternalServerError)
				return
			}
		}
	}
}

type grpcServer struct {
	grpc.UnimplementedAcornServer
}

func (s *grpcServer) Request(ctx context.Context, in *grpc.Request) (*grpc.Response, error) {
	request := Request{
		RequestTime: int(in.RequestTime),
		PayloadSize: int(in.PayloadSize),
		Timeout:     in.Timeout,
		Fail:        in.Fail,
	}

	response := handleRequest(request)

	var err string
	if response.Err != nil {
		err = response.Err.Error()
	}

	return &grpc.Response{
		Hash:    response.Hash,
		Payload: response.Payload,
		Start:   response.Start.Format(time.RFC3339Nano),
		End:     response.End.Format(time.RFC3339Nano),
		Error:   err,
	}, nil
}
