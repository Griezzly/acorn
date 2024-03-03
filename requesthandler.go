package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"time"
)

type Request struct {
	RequestTime int  `json:"requestTime"` // ms
	PayloadSize int  `json:"payloadSize"` // bytes
	Timeout     bool `json:"timeout"`
	Fail        bool `json:"fail"`
}

type ReponseError struct {
	msg string
}

func (e ReponseError) Error() string {
	return e.msg
}

type Response struct {
	Hash    string    `json:"Hash"`
	Payload []byte    `json:"Payload"`
	Start   time.Time `json:"Start"`
	End     time.Time `json:"End"`
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

func handleRequest(request Request) Response {
	begin := time.Now()
	requestHash := computeHash(request, begin)
	log.Println(requestHash + " - request received")
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
