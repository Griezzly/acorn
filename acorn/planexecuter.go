package main

import (
	pb "acorn/grpc"
	"acorn/pkg/logcollector"
	"bytes"
	"fmt"
	"os/exec"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type PlanExecutor struct {
	logCollector *logcollector.LogCollector
}

func (p *PlanExecutor) BlockIP(ip string) error {
	cmd := exec.Command("iptables", "-A", "OUTPUT", "-d", ip, "-j", "DROP")
	err := cmd.Run()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("BlockIP: failed to block %s: %v", ip, err))
	} else {
		p.logCollector.Add(fmt.Sprintf("BlockIP: blocked IP %s", ip))
	}
	return err
}

// Unblock outgoing packets to a specific IP.
func (p *PlanExecutor) UnblockIP(ip string) error {
	cmd := exec.Command("iptables", "-D", "OUTPUT", "-d", ip, "-j", "DROP")
	err := cmd.Run()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("UnblockIP: failed to unblock %s: %v", ip, err))
	} else {
		p.logCollector.Add(fmt.Sprintf("UnblockIP: unblocked IP %s", ip))
	}
	return err
}

// Delay outgoing traffic (ms).
func (p *PlanExecutor) DelayTraffic(delayMs int) error {
	cmd := exec.Command("tc", "qdisc", "add", "dev", "eth0", "root", "netem", "delay", fmt.Sprintf("%dms", delayMs))
	err := cmd.Run()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("DelayTraffic: failed to add %dms delay: %v", delayMs, err))
	} else {
		p.logCollector.Add(fmt.Sprintf("DelayTraffic: applied %dms delay", delayMs))
	}
	return err
}

// Clear any traffic delay.
func (p *PlanExecutor) ClearDelay() error {
	cmd := exec.Command("tc", "qdisc", "del", "dev", "eth0", "root")
	err := cmd.Run()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("ClearDelay: failed: %v", err))
	} else {
		p.logCollector.Add("ClearDelay: delay cleared")
	}
	return err
}

// Introduce packet loss percentage (0-100).
func (p *PlanExecutor) PacketLoss(percent int) error {
	cmd := exec.Command("tc", "qdisc", "add", "dev", "eth0", "root", "netem", "loss", fmt.Sprintf("%d%%", percent))
	err := cmd.Run()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("PacketLoss: failed to add %d%% loss: %v", percent, err))
	} else {
		p.logCollector.Add(fmt.Sprintf("PacketLoss: applied %d%% packet loss", percent))
	}
	return err
}

// Clear packet loss config.
func (p *PlanExecutor) ClearLoss() error {
	cmd := exec.Command("tc", "qdisc", "del", "dev", "eth0", "root")
	err := cmd.Run()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("ClearLoss: failed: %v", err))
	} else {
		p.logCollector.Add("ClearLoss: loss cleared")
	}
	return err
}

// Reserve memory in MB.
func (p *PlanExecutor) ReserveMemory(mb int) []byte {
	p.logCollector.Add(fmt.Sprintf("ReserveMemory: reserving %d MB", mb))
	return make([]byte, mb*1024*1024)
}

// Artificial CPU load for duration.
func (p *PlanExecutor) LoadCPU(coreCount int, loadPerCore float64, duration time.Duration) {
	var wg sync.WaitGroup
	p.logCollector.Add(fmt.Sprintf("LoadCPU: applying %.2f%% load on %d cores for %s",
		loadPerCore*100, coreCount, duration))

	for i := 0; i < coreCount; i++ {
		wg.Add(1)
		go func(core int) {
			defer wg.Done()
			stop := time.Now().Add(duration)
			busyTime := int64(loadPerCore * 100)
			idleTime := 100 - busyTime

			for time.Now().Before(stop) {
				start := time.Now()
				for time.Since(start).Milliseconds() < busyTime {
				}
				time.Sleep(time.Duration(idleTime) * time.Millisecond)
			}
		}(i)
	}
	wg.Wait()
	p.logCollector.Add("LoadCPU: finished load")
}

// Print active TCP connections to logs.
func (p *PlanExecutor) TraceConnections() {
	cmd := exec.Command("ss", "-tanp")
	output, err := cmd.CombinedOutput()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("TraceConnections: error: %v", err))
	} else {
		p.logCollector.Add(fmt.Sprintf("TraceConnections:\n%s", bytes.TrimSpace(output)))
	}
}

// Ping a host and log the RTT result.
func (p *PlanExecutor) PingRTT(host string) {
	cmd := exec.Command("ping", "-c", "1", "-W", "1", host)
	output, err := cmd.CombinedOutput()
	if err != nil {
		p.logCollector.Add(fmt.Sprintf("PingRTT: failed to ping %s: %v", host, err))
	} else {
		p.logCollector.Add(fmt.Sprintf("PingRTT to %s:\n%s", host, bytes.TrimSpace(output)))
	}
}

func (pe *PlanExecutor) Execute(plan *pb.ExecutionPlan) {
	// Start diagnostics monitoring during plan execution
	monitorConfig := &logcollector.MonitoringConfig{
		Interval:     100 * time.Millisecond,
		MetricPrefix: "WORKER_METRIC",
	}
	_ = pe.logCollector.StartMonitoring(monitorConfig)
	defer pe.logCollector.StopMonitoring()

	executionStartTime := time.Now()
	pe.logCollector.Add(fmt.Sprintf("[BENCHMARK_START] node_id=%s plan_start_time=%d execution_start=%d",
		plan.NodeId, plan.StartTime, executionStartTime.UnixNano()))

	type Step struct {
		Timestamp int
		Action    string
		Args      []string
	}

	var steps []Step
	for _, line := range strings.Split(plan.Plan, "\n") {
		parts := strings.SplitN(line, ":", 3)
		if len(parts) < 3 {
			continue
		}
		ts, err := strconv.Atoi(parts[0])
		if err != nil {
			continue
		}
		args := strings.Split(parts[2], ",")
		steps = append(steps, Step{Timestamp: ts, Action: parts[1], Args: args})
	}

	sort.Slice(steps, func(i, j int) bool {
		return steps[i].Timestamp < steps[j].Timestamp
	})

	start := time.Now()
	for _, step := range steps {
		wait := time.Duration(step.Timestamp)*time.Millisecond - time.Since(start)
		if wait > 0 {
			time.Sleep(wait)
		}

		stepStartTime := time.Now()
		pe.logCollector.Add(fmt.Sprintf("[STEP_START] timestamp=%d action=%s args=%v scheduled_at=%d",
			stepStartTime.UnixNano(), step.Action, step.Args, step.Timestamp))

		switch step.Action {
		case "block":
			if len(step.Args) >= 1 {
				_ = pe.BlockIP(step.Args[0])
			}
		case "unblock":
			if len(step.Args) >= 1 {
				_ = pe.UnblockIP(step.Args[0])
			}
		case "delay":
			if len(step.Args) >= 1 {
				delay, _ := strconv.Atoi(step.Args[0])
				_ = pe.DelayTraffic(delay)
			}
		case "loss":
			if len(step.Args) >= 1 {
				loss, _ := strconv.Atoi(step.Args[0])
				_ = pe.PacketLoss(loss)
			}
		case "mem":
			if len(step.Args) >= 1 {
				mb, _ := strconv.Atoi(step.Args[0])
				_ = pe.ReserveMemory(mb)
			}
		case "cpu":
			if len(step.Args) >= 1 {
				load, _ := strconv.ParseFloat(step.Args[0], 64)
				go pe.LoadCPU(runtime.NumCPU(), load, 5*time.Second)
			}
		}

		stepEndTime := time.Now()
		stepDuration := stepEndTime.Sub(stepStartTime)
		pe.logCollector.Add(fmt.Sprintf("[STEP_END] action=%s duration_us=%d",
			step.Action, stepDuration.Microseconds()))
	}

	executionEndTime := time.Now()
	executionDuration := executionEndTime.Sub(executionStartTime)
	pe.logCollector.Add(fmt.Sprintf("[BENCHMARK_END] node_id=%s execution_end=%d duration_ms=%d steps_executed=%d",
		plan.NodeId, executionEndTime.UnixNano(), executionDuration.Milliseconds(), len(steps)))
}
