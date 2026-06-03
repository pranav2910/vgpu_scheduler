package v1alpha1

import "testing"

func TestRecommendedVRAMBytes(t *testing.T) {
	const giB = int64(1) << 30
	cases := []struct{ peak, want int64 }{
		{0, 0},
		{-5, 0},
		{1000, 1150},                    // ×1.15
		{9 * giB, 9*giB + 9*giB*15/100}, // 9 GiB → ~10.35 GiB
		{2 * giB, 2*giB + 2*giB*15/100}, // 2 GiB → ~2.3 GiB
	}
	for _, c := range cases {
		if got := RecommendedVRAMBytes(c.peak); got != c.want {
			t.Errorf("RecommendedVRAMBytes(%d) = %d, want %d", c.peak, got, c.want)
		}
	}
}

func TestConfidence(t *testing.T) {
	cases := []struct {
		obs        int64
		peakStable bool
		want       ProfileConfidence
	}{
		{0, true, ProfileConfidenceLow},
		{19, true, ProfileConfidenceLow},
		{20, true, ProfileConfidenceMedium},
		{99, true, ProfileConfidenceMedium},
		{100, false, ProfileConfidenceMedium}, // enough samples, but the peak is still climbing
		{100, true, ProfileConfidenceHigh},
		{1000, true, ProfileConfidenceHigh},
		{1000, false, ProfileConfidenceMedium},
	}
	for _, c := range cases {
		if got := Confidence(c.obs, c.peakStable); got != c.want {
			t.Errorf("Confidence(obs=%d, stable=%v) = %v, want %v", c.obs, c.peakStable, got, c.want)
		}
	}
}
