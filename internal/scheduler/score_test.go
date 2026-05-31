package scheduler

import "testing"

const giB = int64(1) << 30

// newScoreTestCache builds a 3-node cache for topology scoring tests:
//
//	A: zone nvlink-a, 40 GiB free  (good bin-pack within zone)
//	B: zone nvlink-a, 70 GiB free  (worse bin-pack within zone)
//	C: zone rack-3,   10 GiB free  (best bin-pack overall, but out of zone)
func newScoreTestCache() *VRAMCache {
	c := NewVRAMCache()
	c.UpdateNode("A", 80*giB, 40*giB) // free = 40 GiB
	c.UpdateNode("B", 80*giB, 10*giB) // free = 70 GiB
	c.UpdateNode("C", 80*giB, 70*giB) // free = 10 GiB
	c.SetNodeZone("A", "nvlink-a")
	c.SetNodeZone("B", "nvlink-a")
	c.SetNodeZone("C", "rack-3")
	return c
}

// Without a zone preference, scoring is pure bin-packing: the node with the
// least leftover (C, free 10 GiB for a 10 GiB ask → 0 leftover) wins.
func TestScore_NoPreference_BinPacks(t *testing.T) {
	c := newScoreTestCache()
	scores := ScoreWithTopology(c, []string{"A", "B", "C"}, 10*giB, false, "")
	if len(scores) != 3 {
		t.Fatalf("expected 3 scored nodes, got %d", len(scores))
	}
	if scores[0].NodeName != "C" {
		t.Errorf("no-preference: expected best bin-pack node C first, got %s", scores[0].NodeName)
	}
	// ScoreWithTier must behave identically (it delegates with no zone).
	tier := ScoreWithTier(c, []string{"A", "B", "C"}, 10*giB, false)
	if tier[0].NodeName != "C" {
		t.Errorf("ScoreWithTier should match no-preference ordering; got %s first", tier[0].NodeName)
	}
}

// With a preferred zone, every in-zone node must outrank every out-of-zone node
// (strong weight), and bin-packing must order nodes *within* the preferred zone.
func TestScore_PreferredZone_DominatesBinPack(t *testing.T) {
	c := newScoreTestCache()
	scores := ScoreWithTopology(c, []string{"A", "B", "C"}, 10*giB, false, "nvlink-a")
	if len(scores) != 3 {
		t.Fatalf("expected 3 scored nodes, got %d", len(scores))
	}

	// A (in-zone, better bin-pack) first; B (in-zone) second; C (out-of-zone,
	// best raw bin-pack) must be LAST despite its superior packing.
	if scores[0].NodeName != "A" {
		t.Errorf("expected in-zone best-bin-pack node A first, got %s", scores[0].NodeName)
	}
	if scores[2].NodeName != "C" {
		t.Errorf("expected out-of-zone node C last, got %s", scores[2].NodeName)
	}

	// Explicit invariant: both in-zone nodes outrank the out-of-zone node.
	var cTotal, aTotal, bTotal int64
	for _, s := range scores {
		switch s.NodeName {
		case "A":
			aTotal = s.Score.Total
		case "B":
			bTotal = s.Score.Total
		case "C":
			cTotal = s.Score.Total
		}
	}
	if !(aTotal > cTotal && bTotal > cTotal) {
		t.Errorf("in-zone nodes must beat out-of-zone: A=%d B=%d C=%d", aTotal, bTotal, cTotal)
	}
	// And the zone bonus must actually be recorded on in-zone nodes only.
	for _, s := range scores {
		wantBonus := s.NodeName == "A" || s.NodeName == "B"
		got := s.Score.ZoneScore == topologyZoneMatchBonus
		if got != wantBonus {
			t.Errorf("node %s: zone bonus applied=%v, want %v", s.NodeName, got, wantBonus)
		}
	}
}

// A preference for a zone that no node is in must not crash and must fall back
// to pure bin-packing (soft preference — never a hard filter).
func TestScore_PreferredZone_UnknownFallsBackToBinPack(t *testing.T) {
	c := newScoreTestCache()
	scores := ScoreWithTopology(c, []string{"A", "B", "C"}, 10*giB, false, "does-not-exist")
	if len(scores) != 3 {
		t.Fatalf("expected 3 scored nodes, got %d", len(scores))
	}
	if scores[0].NodeName != "C" {
		t.Errorf("unknown zone should fall back to bin-pack (C first), got %s", scores[0].NodeName)
	}
	for _, s := range scores {
		if s.Score.ZoneScore != 0 {
			t.Errorf("no node should get a zone bonus for an unmatched zone; %s got %d", s.NodeName, s.Score.ZoneScore)
		}
	}
}
