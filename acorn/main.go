package lair

import (
	pb "acorn/grpc"
	"context"
	"fmt"
	"google.golang.org/grpc"
	"log"
	"os/exec"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/cpu"
	"github.com/shirou/gopsutil/mem"
	netmon "github.com/shirou/gopsutil/net"
)

func syncClock(ntpServer string) error {
	log.Printf("Syncing clock with NTP server: %s", ntpServer)
	cmd := exec.Command("sudo", "ntpdate", "-u", ntpServer)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to sync time: %v - %s", err, output)
	}
	log.Printf("NTP sync output: %s", output)
	return nil
}

func blockIP(ip string) error {
	cmd := exec.Command("iptables", "-A", "OUTPUT", "-d", ip, "-j", "DROP")
	return cmd.Run()
}

func unblockIP(ip string) error {
	cmd := exec.Command("iptables", "-D", "OUTPUT", "-d", ip, "-j", "DROP")
	return cmd.Run()
}

func delayTraffic(delayMs int) error {
	cmd := exec.Command("tc", "qdisc", "add", "dev", "eth0", "root", "netem", "delay", fmt.Sprintf("%dms", delayMs))
	return cmd.Run()
}

func clearDelay() error {
	cmd := exec.Command("tc", "qdisc", "del", "dev", "eth0", "root")
	return cmd.Run()
}

func packetLoss(percent int) error {
	cmd := exec.Command("tc", "qdisc", "add", "dev", "eth0", "root", "netem", "loss", fmt.Sprintf("%d%%", percent))
	return cmd.Run()
}

func clearLoss() error {
	cmd := exec.Command("tc", "qdisc", "del", "dev", "eth0", "root")
	return cmd.Run()
}

func reserveMemory(mb int) []byte {
	log.Printf("Reserving %dMB of memory", mb)
	return make([]byte, mb*1024*1024)
}

func loadCPU(coreCount int, loadPerCore float64, duration time.Duration) {
	var wg sync.WaitGroup
	log.Printf("Applying %.2f%% load on %d cores for %s", loadPerCore*100, coreCount, duration)

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
}

func traceConnections() {
	cmd := exec.Command("ss", "-tanp")
	output, err := cmd.CombinedOutput()
	if err == nil {
		log.Printf("Active connections:\n%s", output)
	}
}

func pingRTT(host string) {
	cmd := exec.Command("ping", "-c", "1", "-W", "1", host)
	output, err := cmd.CombinedOutput()
	if err == nil {
		log.Printf("Ping RTT to %s:\n%s", host, output)
	}
}

func monitorDiagnostics(stopCh <-chan struct{}) {
	go func() {
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()

		for {
			select {
			case <-stopCh:
				return
			case <-ticker.C:
				cpuPercents, _ := cpu.Percent(0, false)
				vmStat, _ := mem.VirtualMemory()
				netIO, _ := netmon.IOCounters(false)

				cpuLoad := 0.0
				if len(cpuPercents) > 0 {
					cpuLoad = cpuPercents[0]
				}

				netIn, netOut := uint64(0), uint64(0)
				if len(netIO) > 0 {
					netIn = netIO[0].BytesRecv
					netOut = netIO[0].BytesSent
				}

				log.Printf("Diagnostics - CPU: %.2f%%, Mem: %.2f%%, NetIn: %dB, NetOut: %dB",
					cpuLoad, vmStat.UsedPercent, netIn, netOut)

				traceConnections()
				pingRTT("8.8.8.8")
			}
		}
	}()
}

// New function to parse and execute an execution plan
func executePlan(plan string) {
	type Step struct {
		Timestamp int
		Action    string
		Args      []string
	}

	var steps []Step
	for _, line := range strings.Split(plan, "\n") {
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

		log.Printf("Executing step: %v", step)
		switch step.Action {
		case "block":
			if len(step.Args) >= 1 {
				_ = blockIP(step.Args[0])
			}
		case "unblock":
			if len(step.Args) >= 1 {
				_ = unblockIP(step.Args[0])
			}
		case "delay":
			if len(step.Args) >= 1 {
				delay, _ := strconv.Atoi(step.Args[0])
				_ = delayTraffic(delay)
			}
		case "loss":
			if len(step.Args) >= 1 {
				loss, _ := strconv.Atoi(step.Args[0])
				_ = packetLoss(loss)
			}
		case "mem":
			if len(step.Args) >= 1 {
				mb, _ := strconv.Atoi(step.Args[0])
				_ = reserveMemory(mb)
			}
		case "cpu":
			if len(step.Args) >= 1 {
				load, _ := strconv.ParseFloat(step.Args[0], 64)
				go loadCPU(runtime.NumCPU(), load, 5*time.Second)
			}
		}
	}
}

func generateExecutionPlan() string {
	return strings.Join([]string{
		"1000:block:10.0.0.5",
		"2000:delay:150",
		"3000:loss:10",
		"4000:mem:512",
		"5000:cpu:0.6",
		"6000:unblock:10.0.0.5",
	}, "\n")
}

// main remains mostly unchanged, but plan execution moved
func main() {

	conn, err := grpc.Dial("localhost:50051", grpc.WithInsecure())
	if err != nil {
		log.Fatalf("Did not connect: %v", err)
	}
	defer conn.Close()
	c := pb.NewBenchmarkOrchestratorClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	// Register Node
	res, err := c.RegisterNode(ctx, &pb.NodeInfo{NodeId: "node-1", Ip: "192.168.1.2", Specs: "4vCPU, 8GB RAM"})
	if err != nil {
		log.Fatalf("Register failed: %v", err)
	}
	log.Printf("Registration response: %s", res.Status)

	// TODO: Receive execution plan from orchestrator
	plan := generateExecutionPlan()

	// Sync Clock before running benchmark
	if err := syncClock("pool.ntp.org"); err != nil {
		log.Printf("Warning: NTP sync failed: %v", err)
	}

	// Monitor and Execute Plan
	stopCh := make(chan struct{})
	monitorDiagnostics(stopCh)
	go executePlan(plan)

	time.Sleep(10 * time.Second)
	close(stopCh)

	logs, err := c.CollectLogs(ctx, &pb.LogRequest{NodeId: "node-1"})
	if err != nil {
		log.Fatalf("Collect failed: %v", err)
	}
	log.Printf("Logs: %s", logs.Logs)
}
