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

	// topologyZoneMatchBonus is added to a node's score when it matches the
	// workload's preferred topology zone. Phase 2.5a: "strong" weight — it is
	// an order of magnitude above the bin-pack range (~80e9), so any in-zone
	// node outranks every out-of-zone node, and bin-packing only orders nodes
	// *within* the preferred zone. Soft preference: a workload still schedules
	// out-of-zone if its zone is full (the bonus is purely additive, never a
	// filter). Decision locked with user: soft-only, strong weight.
	topologyZoneMatchBonus = int64(1_000_000_000_000)
)

type ScoreBreakdown struct {
	BinPackScore       int64
	FragmentationScore int64
	ZoneScore          int64
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
//
// Back-compat shim: delegates to ScoreWithTopology with no zone preference.
func ScoreWithTier(cache *VRAMCache, validNodes []string, requestedBytes int64, bestEffort bool) []NodeScore {
	return ScoreWithTopology(cache, validNodes, requestedBytes, bestEffort, "")
}

// ScoreWithTopology ranks eligible nodes by bin-packing efficiency, fragmentation
// penalty, tier, and — Phase 2.5a — topology-zone affinity. When preferredZone is
// non-empty, nodes whose TopologyZone matches it receive topologyZoneMatchBonus,
// which dominates the bin-pack range so in-zone nodes always outrank out-of-zone
// nodes (with bin-packing ordering within each zone). The preference is soft: if
// no in-zone node has capacity, the workload still schedules out-of-zone — the
// caller is expected to surface a TopologyPreferenceMiss condition in that case.
func ScoreWithTopology(cache *VRAMCache, validNodes []string, requestedBytes int64, bestEffort bool, preferredZone string) []NodeScore {
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

		// Topology-zone affinity (Phase 2.5a): strong additive bonus for an
		// in-zone node. Only applies when the workload expressed a preference.
		zone := int64(0)
		if preferredZone != "" && node.TopologyZone == preferredZone {
			zone = topologyZoneMatchBonus
		}

		total := binPack + frag + zone
		if bestEffort {
			total -= BestEffortPenalty
		}

		scores = append(scores, NodeScore{
			NodeName: nodeName,
			Score: ScoreBreakdown{
				BinPackScore:       binPack,
				FragmentationScore: frag,
				ZoneScore:          zone,
				Total:              total,
			},
		})
	}

	sort.Slice(scores, func(i, j int) bool {
		return scores[i].Score.Total > scores[j].Score.Total
	})

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
