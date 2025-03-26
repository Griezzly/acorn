package lair

import (
	pb "acorn/grpc"
	"context"
	"fmt"
	"google.golang.org/grpc"
	"log"
	"math"
	"net"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/cpu"
	"github.com/shirou/gopsutil/mem"
	netmon "github.com/shirou/gopsutil/net"
)

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
			}
		}
	}()
}

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

	// Send Execution Plan
	ack, err := c.SendExecutionPlan(ctx, &pb.ExecutionPlan{NodeId: "node-1", Plan: "block:10.0.0.1,delay:100,loss:20,mem:500,cpu:0.5"})
	if err != nil {
		log.Fatalf("Plan failed: %v", err)
	}
	log.Printf("Plan ack: %s", ack.Status)

	// Example manipulations (demo only)
	plan := "block:10.0.0.1,delay:100,loss:20,mem:500,cpu:0.5"
	applied := make(map[string]bool)
	var memoryReserved []byte

	for _, action := range strings.Split(plan, ",") {
		switch {
		case strings.HasPrefix(action, "block:"):
			ip := strings.TrimPrefix(action, "block:")
			if err := blockIP(ip); err != nil {
				log.Printf("Failed to block IP %s: %v", ip, err)
			} else {
				applied["block"] = true
			}
		case strings.HasPrefix(action, "delay:"):
			d := strings.TrimPrefix(action, "delay:")
			delay, _ := time.ParseDuration(d + "ms")
			if err := delayTraffic(int(delay.Milliseconds())); err != nil {
				log.Printf("Failed to apply delay: %v", err)
			} else {
				applied["delay"] = true
			}
		case strings.HasPrefix(action, "loss:"):
			p := strings.TrimPrefix(action, "loss:")
			var percent int
			fmt.Sscanf(p, "%d", &percent)
			if err := packetLoss(percent); err != nil {
				log.Printf("Failed to apply loss: %v", err)
			} else {
				applied["loss"] = true
			}
		case strings.HasPrefix(action, "mem:"):
			m := strings.TrimPrefix(action, "mem:")
			var mb int
			fmt.Sscanf(m, "%d", &mb)
			memoryReserved = reserveMemory(mb)
		case strings.HasPrefix(action, "cpu:"):
			c := strings.TrimPrefix(action, "cpu:")
			var load float64
			fmt.Sscanf(c, "%f", &load)
			go loadCPU(runtime.NumCPU(), load, 5*time.Second)
		}
	}

	// Revert after a short delay for demo
	time.Sleep(6 * time.Second)

	if applied["block"] {
		if err := unblockIP("10.0.0.1"); err != nil {
			log.Printf("Failed to unblock IP: %v", err)
		} else {
			log.Println("IP unblocked")
		}
	}

	if applied["delay"] || applied["loss"] {
		if err := clearDelay(); err != nil {
			log.Printf("Failed to clear delay: %v", err)
		} else {
			log.Println("Delay cleared")
		}
		if err := clearLoss(); err != nil {
			log.Printf("Failed to clear loss: %v", err)
		} else {
			log.Println("Loss cleared")
		}
	}

	_ = memoryReserved // Ensure it's not optimized away

	// Collect Logs
	logs, err := c.CollectLogs(ctx, &pb.LogRequest{NodeId: "node-1"})
	if err != nil {
		log.Fatalf("Collect failed: %v", err)
	}
	log.Printf("Logs: %s", logs.Logs)
}
