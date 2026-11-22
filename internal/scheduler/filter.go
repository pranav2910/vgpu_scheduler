package scheduler

import (
	"fmt"
	"log"
)

type FilterResult struct {
	NodeName string
	Passed   bool
	Reason   string
	Details  string // SRE-level telemetry
}

// Filter evaluates a node and returns a structured result with a rejection reason.
func Filter(cache *VRAMCache, nodeName string, requestedBytes int64) FilterResult {
	fits, reason, details := cache.CanFit(nodeName, requestedBytes) // was: fits, reason (missing 3rd return)

	if !fits {
		// Log demoted to debug — on big clusters this fires O(nodes*scheduleAttempts).
		if _ = details; false {
			log.Printf("Filter Rejected: Node [%s] - %s: %s", nodeName, reason, details)
		}
		return FilterResult{
			NodeName: nodeName,
			Passed:   false,
			Reason:   reason,
			Details:  details,
		}
	}

	return FilterResult{
		NodeName: nodeName,
		Passed:   true,
		Reason:   "PASSED",
		Details:  fmt.Sprintf("Capacity verified for %d bytes", requestedBytes),
	}
}
