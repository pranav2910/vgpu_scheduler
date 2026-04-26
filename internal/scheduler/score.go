package scheduler

import (
	"sort"
)

const (
	// scoreWeightVRAMBytes is the reference VRAM used for bin-packing score normalisation (80 GiB).
	scoreWeightVRAMBytes = int64(80_000_000_000)
	// fragmentThresholdBytes is the minimum leftover considered "usable".
	fragmentThresholdBytes = int64(4_000_000_000)
	// fragmentPenaltyBytes is the magnitude of the penalty; the sign is applied
	// at the use site. Bug #12 fix.
	fragmentPenaltyBytes = int64(5_000_000_000)
)

type ScoreBreakdown struct {
	BinPackScore       int64
	FragmentationScore int64
	Total              int64
}

type NodeScore struct {
	NodeName string
	Score    ScoreBreakdown
}

// BestEffortPenalty lowers the score for BestEffort claims so Guaranteed
// claims win when both compete for the same scarce node. Bug #19.
const BestEffortPenalty = int64(1_000_000_000)

// Score ranks eligible nodes by bin-packing efficiency and fragmentation penalty.
// Uses SnapshotAllNodes so the loop is lock-free. Bug #9 fix.
// ScoreWithTier is the tier-aware scoring entrypoint. Bug #19.
func ScoreWithTier(cache *VRAMCache, validNodes []string, requestedBytes int64, bestEffort bool) []NodeScore {
	snaps := cache.SnapshotAllNodes()
	byName := make(map[string]NodeSnapshot, len(snaps))
	for _, s := range snaps {
		byName[s.NodeName] = s
	}

	var scores []NodeScore

	for _, nodeName := range validNodes {
		node, exists := byName[nodeName]
		if !exists {
			continue
		}

		leftover := node.FreeVRAMBytes - requestedBytes

		// Bin-packing: higher score → less leftover (filling nearly-full nodes first).
		binPack := scoreWeightVRAMBytes - leftover

		// Fragmentation penalty: unusable slivers below the threshold are penalised.
		frag := int64(0)
		if leftover > 0 && leftover < fragmentThresholdBytes {
			frag = -fragmentPenaltyBytes
		}

		total := binPack + frag
		if bestEffort {
			total -= BestEffortPenalty
		}

		scores = append(scores, NodeScore{
			NodeName: nodeName,
			Score: ScoreBreakdown{
				BinPackScore:       binPack,
				FragmentationScore: frag,
				Total:              total,
			},
		})
	}

	sort.Slice(scores, func(i, j int) bool {
		return scores[i].Score.Total > scores[j].Score.Total
	})

	// Scoring winner log removed from hot path (round-3 fix). If you need it,
	// enable it via a debug build tag or structured logging at V(1).

	return scores
}

// Score is the back-compat wrapper for callers that don't care about tiers.
func Score(cache *VRAMCache, validNodes []string, requestedBytes int64) []NodeScore {
	return ScoreWithTier(cache, validNodes, requestedBytes, false)
}

// ─── Layer 2 Phase 2.1a: Job-aware scoring helpers ──────────────────────────

// priorityBonus maps a Job's priority (0-1000) into a scoring contribution.
// We scale to 0-100 so it dominates workloadAffinityBonus but doesn't drown
// out the bin-pack score, which is in the hundreds of GiB range.
func priorityBonus(priority int32) int64 {
	if priority < 0 {
		return 0
	}
	if priority > 1000 {
		priority = 1000
	}
	return int64(priority) / 10
}

// workloadAffinityBonus is a small class-aware adjustment. The values are
// intentionally tiny relative to priorityBonus — they break ties between
// same-priority claims rather than overriding priority.
func workloadAffinityBonus(class string) int64 {
	switch class {
	case "Training":
		return 10
	case "Inference":
		return 5
	case "Batch":
		return -5
	case "Interactive":
		return 0
	default:
		return 0
	}
}
