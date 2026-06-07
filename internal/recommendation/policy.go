// Package recommendation holds the shared Phase 3.7 policy that turns a workload's
// learned VRAM recommendation into a future-request policy. The SAME decision
// logic is used by the controller (advisory surfaces) and the VGPUJob validating
// webhook (requireOverride enforcement), so the two can never disagree.
package recommendation

import (
	"log"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
)

// Mode selects how strongly the platform acts on an under-provisioned request.
type Mode string

const (
	// RecommendOnly (default): surface the recommendation — Underprovisioned
	// condition + recommended-vram annotation + metric. Never an event, never a block.
	RecommendOnly Mode = "recommendOnly"
	// Warn: everything RecommendOnly does, plus a Warning event on the Job.
	Warn Mode = "warn"
	// RequireOverride: everything Warn does, plus REJECT the CREATE of an
	// under-provisioned Job unless it carries the override annotation. Only ever
	// blocks at Medium+ confidence — never on a thin (Low) profile.
	RequireOverride Mode = "requireOverride"
)

// OverrideAnnotation, set to "true" on a VGPUJob, admits an under-provisioned
// request even in requireOverride mode (an explicit "I know, run it anyway").
const OverrideAnnotation = "infrastructure.pranav2910.com/override-recommendation"

// TolerancePercent: a request within this percentage of the recommendation is
// treated as adequately sized (no advisory, no block) — avoids nagging on rounding.
const TolerancePercent = 10

// ParseMode maps an env value to a Mode, defaulting to RecommendOnly (the least
// intrusive mode) and warning on an unrecognized value — fail-safe by construction.
func ParseMode(s string) Mode {
	switch Mode(s) {
	case RecommendOnly, Warn, RequireOverride:
		return Mode(s)
	case "":
		return RecommendOnly
	default:
		log.Printf("[recommendation] %q is not a valid VGPU_RECOMMENDATION_MODE "+
			"(want recommendOnly|warn|requireOverride) — using recommendOnly", s)
		return RecommendOnly
	}
}

// ConfidentEnough reports whether a profile is statistically trustworthy enough to
// ACT on (advise or enforce). Below this (Low), recommendations are directional
// only and must never drive a block. This is the safety gate.
func ConfidentEnough(c vgpuv1alpha1.ProfileConfidence) bool {
	return c == vgpuv1alpha1.ProfileConfidenceMedium || c == vgpuv1alpha1.ProfileConfidenceHigh
}

// Undersized reports whether `requested` is below `recommended` by more than the
// tolerance. Zero/unknown values are never undersized.
func Undersized(requested, recommended int64) bool {
	if requested <= 0 || recommended <= 0 {
		return false
	}
	threshold := recommended - (recommended*TolerancePercent)/100 // recommended × 0.9
	return requested < threshold
}

// EmitsEvent reports whether a mode should fire the Warning event for an
// under-provisioned request (warn and requireOverride do; recommendOnly does not).
func EmitsEvent(m Mode) bool {
	return m == Warn || m == RequireOverride
}

// Blocks reports whether requireOverride must REJECT this CREATE, and is the
// single source of truth for the enforcement decision. It blocks only when ALL
// hold: mode is requireOverride, the profile is confident enough (Medium+), the
// request is undersized beyond tolerance, and no override annotation is present.
func Blocks(mode Mode, requested, recommended int64, conf vgpuv1alpha1.ProfileConfidence, hasOverride bool) bool {
	return mode == RequireOverride &&
		ConfidentEnough(conf) &&
		Undersized(requested, recommended) &&
		!hasOverride
}
