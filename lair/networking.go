package main

import (
	"fmt"
	"log"
	"os/exec"
	"strings"
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

// generateExecutionPlanForNode creates a simple chaos engineering plan for a benchmark node.
// nodeIP: the IP of the node that will execute this plan
// targetIPs: IPs of other nodes/services that can be targeted for network chaos
func generateExecutionPlanForNode(nodeIP string, targetIPs []string) (string, int64) {
	var steps []string

	// Basic plan: introduce some network chaos and resource constraints
	// Targeting first available service if targetIPs exist
	if len(targetIPs) > 0 {
		steps = append(steps, fmt.Sprintf("1000:block:%s", targetIPs[0]))
		steps = append(steps, fmt.Sprintf("6000:unblock:%s", targetIPs[0]))
	}

	// Network delays and packet loss
	steps = append(steps, "2000:delay:150")
	steps = append(steps, "3000:loss:10")

	// Resource constraints
	steps = append(steps, "4000:mem:512")
	steps = append(steps, "5000:cpu:0.6")

	plan := strings.Join(steps, "\n")
	start := time.Now().Add(5 * time.Second).UnixMilli() // start 5 seconds from now
	return plan, start
}
