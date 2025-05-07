package lair

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

func generateExecutionPlan() (string, int64) {
	plan := strings.Join([]string{
		"1000:block:10.0.0.5",
		"2000:delay:150",
		"3000:loss:10",
		"4000:mem:512",
		"5000:cpu:0.6",
		"6000:unblock:10.0.0.5",
	}, "\n")
	start := time.Now().Add(3 * time.Second).UnixMilli() // start 3 seconds from now
	return plan, start
}
