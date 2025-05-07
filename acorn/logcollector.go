package acorn

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

// Thread-safe log collector.
type LogCollector struct {
	mu   sync.Mutex
	logs [][2]string // Each log is [timestamp(uint64 nanoseconds as string), line]
}

func (lc *LogCollector) Add(line string) {
	ts := strconv.FormatInt(time.Now().UnixNano(), 10)
	lc.mu.Lock()
	lc.logs = append(lc.logs, [2]string{ts, line})
	lc.mu.Unlock()
}

// GetAndReset returns all collected logs and resets the collector.
func (lc *LogCollector) GetAndReset() [][2]string {
	lc.mu.Lock()
	logsCopy := make([][2]string, len(lc.logs))
	copy(logsCopy, lc.logs)
	lc.logs = nil
	lc.mu.Unlock()
	return logsCopy
}

// LokiPusher sends a batch of logs to a Loki server.
type LokiPusher struct {
	url    string
	labels map[string]string
}

// NewLokiPusher creates a new pusher to the given Loki instance.
func NewLokiPusher(url string, labels map[string]string) *LokiPusher {
	return &LokiPusher{url: url, labels: labels}
}

// Push sends logs to Loki in a single stream.
func (lp *LokiPusher) Push(logs [][2]string) error {
	if len(logs) == 0 {
		return nil
	}
	stream := map[string]interface{}{
		"stream": lp.labels,
		"values": logs,
	}
	payload := map[string]interface{}{
		"streams": []interface{}{stream},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal logs for Loki: %w", err)
	}

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Post(lp.url, "application/json", bytes.NewReader(body))
	if err != nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Fallback to local filesystem logging
		fallbackErr := lp.appendLogsToFile("loki_fallback.log", logs)
		if fallbackErr != nil {
			// Chain both errors for diagnosability
			return fmt.Errorf("Loki push failed: %v; fallback log failed: %w", err, fallbackErr)
		}
		return fmt.Errorf("Loki push failed, logs appended to local file: %w", err)
	}
	defer resp.Body.Close()
	return nil

}

func (lp *LokiPusher) appendLogsToFile(path string, logs [][2]string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	for _, entry := range logs {
		// Format: timestamp line\n
		if _, err := f.WriteString(fmt.Sprintf("%s %s\n", entry[0], entry[1])); err != nil {
			return err
		}
	}
	return nil
}
