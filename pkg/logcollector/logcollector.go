package logcollector

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/shirou/gopsutil/cpu"
	"github.com/shirou/gopsutil/mem"
	netmon "github.com/shirou/gopsutil/net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

// Thread-safe log collector.
type LogCollector struct {
	mu             sync.Mutex
	logs           [][2]string // Each log is [timestamp(uint64 nanoseconds as string), line]
	monitorStopCh  chan struct{}
	monitorRunning bool
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

// MonitoringConfig holds configuration for diagnostics monitoring
type MonitoringConfig struct {
	Interval        time.Duration // How often to collect metrics
	EnableConnTrace bool          // Enable connection tracing (can be expensive)
	EnablePing      bool          // Enable ping RTT checks
	PingTarget      string        // Target for ping checks (default: 8.8.8.8)
	MetricPrefix    string        // Prefix for metric logs (default: METRIC)
}

// DefaultMonitoringConfig returns sensible defaults
func DefaultMonitoringConfig() *MonitoringConfig {
	return &MonitoringConfig{
		Interval:        100 * time.Millisecond,
		EnableConnTrace: false, // Disabled by default as it can be expensive
		EnablePing:      false, // Disabled by default to reduce network noise
		PingTarget:      "8.8.8.8",
		MetricPrefix:    "METRIC",
	}
}

// StartMonitoring begins collecting system diagnostics at the configured interval
// Returns an error if monitoring is already running
func (lc *LogCollector) StartMonitoring(config *MonitoringConfig) error {
	lc.mu.Lock()
	if lc.monitorRunning {
		lc.mu.Unlock()
		return fmt.Errorf("monitoring already running")
	}

	if config == nil {
		config = DefaultMonitoringConfig()
	}

	lc.monitorStopCh = make(chan struct{})
	lc.monitorRunning = true
	lc.mu.Unlock()

	go lc.monitorLoop(config)
	return nil
}

// StopMonitoring stops the diagnostics collection
func (lc *LogCollector) StopMonitoring() {
	lc.mu.Lock()
	if !lc.monitorRunning {
		lc.mu.Unlock()
		return
	}

	close(lc.monitorStopCh)
	lc.monitorRunning = false
	lc.mu.Unlock()
}

func (lc *LogCollector) monitorLoop(config *MonitoringConfig) {
	ticker := time.NewTicker(config.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-lc.monitorStopCh:
			return
		case <-ticker.C:
			lc.collectMetrics(config)
		}
	}
}

func (lc *LogCollector) collectMetrics(config *MonitoringConfig) {
	// Collect CPU metrics
	cpuPercents, err := cpu.Percent(0, false)
	cpuLoad := 0.0
	if err == nil && len(cpuPercents) > 0 {
		cpuLoad = cpuPercents[0]
	}

	// Collect memory metrics
	vmStat, err := mem.VirtualMemory()
	memUsedPercent := 0.0
	memUsedBytes := uint64(0)
	if err == nil {
		memUsedPercent = vmStat.UsedPercent
		memUsedBytes = vmStat.Used
	}

	// Collect network I/O metrics
	netIO, err := netmon.IOCounters(false)
	netIn, netOut := uint64(0), uint64(0)
	if err == nil && len(netIO) > 0 {
		netIn = netIO[0].BytesRecv
		netOut = netIO[0].BytesSent
	}

	// Log structured metrics that can be parsed by LogQL
	lc.Add(fmt.Sprintf("[%s] cpu_percent=%.2f mem_percent=%.2f mem_bytes=%d net_rx_bytes=%d net_tx_bytes=%d",
		config.MetricPrefix, cpuLoad, memUsedPercent, memUsedBytes, netIn, netOut))

	// Optional: trace connections
	if config.EnableConnTrace {
		lc.traceConnections()
	}

	// Optional: ping RTT
	if config.EnablePing {
		lc.pingRTT(config.PingTarget)
	}
}

// traceConnections logs active TCP connections
func (lc *LogCollector) traceConnections() {
	cmd := exec.Command("ss", "-tanp")
	output, err := cmd.CombinedOutput()
	if err != nil {
		lc.Add(fmt.Sprintf("[CONN_TRACE] error: %v", err))
	} else {
		lc.Add(fmt.Sprintf("[CONN_TRACE]\n%s", bytes.TrimSpace(output)))
	}
}

// pingRTT measures round-trip time to a target host
func (lc *LogCollector) pingRTT(host string) {
	cmd := exec.Command("ping", "-c", "1", "-W", "1", host)
	output, err := cmd.CombinedOutput()
	if err != nil {
		lc.Add(fmt.Sprintf("[PING_RTT] target=%s error=%v", host, err))
	} else {
		lc.Add(fmt.Sprintf("[PING_RTT] target=%s output=%s", host, bytes.TrimSpace(output)))
	}
}
