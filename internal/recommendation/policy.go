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
	// AutoResize (3.7b): instead of warning/blocking, a mutating webhook RAISES an
	// under-provisioned request up to the recommendation (capped at fleet max) at
	// CREATE — transparently (audit annotations + condition + event). Only at
	// Medium+ confidence, never when overridden, and it NEVER lowers a request.
	AutoResize Mode = "autoResize"
)

const (
	// OverrideAnnotation, set to "true" on a VGPUJob, opts out of enforcement — it
	// admits an under-provisioned request in requireOverride mode AND suppresses
	// autoResize (an explicit "I know, run it at my size").
	OverrideAnnotation = "infrastructure.pranav2910.com/override-recommendation"
	// Audit annotations stamped by the autoResize mutating webhook (3.7b) so a
	// resize is never silent — the user can read both numbers off the object.
	OriginalVRAMAnnotation    = "infrastructure.pranav2910.com/original-vram-bytes"
	AutoResizedVRAMAnnotation = "infrastructure.pranav2910.com/autoresized-vram-bytes"
	AutoResizedAnnotation     = "infrastructure.pranav2910.com/autoresized"      // "true" marker for the controller
	AutoResizeCappedAnnotation = "infrastructure.pranav2910.com/autoresize-capped" // value = the uncapped recommendation
)

// TolerancePercent: a request within this percentage of the recommendation is
// treated as adequately sized (no advisory, no block) — avoids nagging on rounding.
const TolerancePercent = 10

// FleetMaxBytes caps an autoResize: a recommendation above a single card's
// capacity is clamped here (matches the VGPUClaim validator's bound). A capped
// resize is flagged so the user learns the workload may need a larger GPU class
// or model parallelism.
const FleetMaxBytes int64 = 85_899_345_920 // 80 GiB

// ParseMode maps an env value to a Mode, defaulting to RecommendOnly (the least
// intrusive mode) and warning on an unrecognized value — fail-safe by construction.
func ParseMode(s string) Mode {
	switch Mode(s) {
	case RecommendOnly, Warn, RequireOverride, AutoResize:
		return Mode(s)
	case "":
		return RecommendOnly
	default:
		log.Printf("[recommendation] %q is not a valid VGPU_RECOMMENDATION_MODE "+
			"(want recommendOnly|warn|requireOverride|autoResize) — using recommendOnly", s)
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

// ResizeTarget decides whether autoResize should RAISE `requested`, and to what.
// It returns the new request, whether a resize happens, and whether the
// recommendation was capped at `fleetMax`. Invariants:
//   - never resizes when overridden, on a Low-confidence profile, or when the
//     request is already adequate (within tolerance);
//   - NEVER lowers a request — if the (possibly capped) target is ≤ requested it
//     is a no-op (e.g. an over-provisioned request, or one already at fleet max);
//   - clamps to fleetMax and reports capped=true when the recommendation exceeds it.
func ResizeTarget(requested, recommended, fleetMax int64, conf vgpuv1alpha1.ProfileConfidence, hasOverride bool) (newReq int64, resized, capped bool) {
	if hasOverride || !ConfidentEnough(conf) || !Undersized(requested, recommended) {
		return requested, false, false
	}
	target := recommended
	if fleetMax > 0 && target > fleetMax {
		target = fleetMax
		capped = true
	}
	if target <= requested {
		return requested, false, false // never lower; capping pulled it to/below the request
	}
	return target, true, capped
}
