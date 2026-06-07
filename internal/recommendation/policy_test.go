package recommendation

import (
	"testing"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

func TestParseMode(t *testing.T) {
	cases := map[string]Mode{
		"recommendOnly":   RecommendOnly,
		"warn":            Warn,
		"requireOverride": RequireOverride,
		"":                RecommendOnly, // unset → safe default
		"BLOCK":           RecommendOnly, // unknown → safe default
		"garbage":         RecommendOnly,
	}
	for in, want := range cases {
		if got := ParseMode(in); got != want {
			t.Errorf("ParseMode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUndersized(t *testing.T) {
	const rec = int64(24_000_000_000) // ~24 GB; threshold = 90% = 21.6 GB
	cases := []struct {
		name      string
		requested int64
		want      bool
	}{
		{"well under", 16_000_000_000, true},
		{"just under threshold", 21_000_000_000, true},
		{"within 10% tolerance", 22_000_000_000, false},
		{"equal", rec, false},
		{"over", 30_000_000_000, false},
		{"zero requested", 0, false},
	}
	for _, c := range cases {
		if got := Undersized(c.requested, rec); got != c.want {
			t.Errorf("%s: Undersized(%d, %d) = %v, want %v", c.name, c.requested, rec, got, c.want)
		}
	}
	if Undersized(16, 0) {
		t.Error("zero recommended must never be undersized")
	}
}

// The enforcement decision matrix — this is the heart of 3.7a.
func TestBlocks(t *testing.T) {
	const (
		req = int64(16_000_000_000) // 16 GB, undersized vs 24 GB
		rec = int64(24_000_000_000)
	)
	hi := vgpuv1alpha1.ProfileConfidenceHigh
	med := vgpuv1alpha1.ProfileConfidenceMedium
	lo := vgpuv1alpha1.ProfileConfidenceLow

	cases := []struct {
		name        string
		mode        Mode
		conf        vgpuv1alpha1.ProfileConfidence
		hasOverride bool
		want        bool
	}{
		{"recommendOnly never blocks", RecommendOnly, hi, false, false},
		{"warn never blocks", Warn, hi, false, false},
		{"requireOverride + High + no override → BLOCK", RequireOverride, hi, false, true},
		{"requireOverride + Medium + no override → BLOCK", RequireOverride, med, false, true},
		{"requireOverride + Low + no override → allow (safety gate)", RequireOverride, lo, false, false},
		{"requireOverride + High + override → allow", RequireOverride, hi, true, false},
	}
	for _, c := range cases {
		if got := Blocks(c.mode, req, rec, c.conf, c.hasOverride); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}

	// An adequately-sized request is never blocked, even in requireOverride+High.
	if Blocks(RequireOverride, rec, rec, hi, false) {
		t.Error("an adequately-sized request must never be blocked")
	}
}
