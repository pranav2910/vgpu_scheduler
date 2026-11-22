package controller

import "strings"

// gangAnnotationPrefix matches all annotations the gang scheduling feature
// stamps on its objects (gang reference, reservation reference, gang index,
// etc.). We propagate exactly these from Job → Claim → Slice; no other
// annotations cross object boundaries (avoids leaking kubectl bookkeeping,
// last-applied-config, etc. into derived objects).
const gangAnnotationPrefix = "gang.vgpu.pranav2910.com/"

// topologyAnnotationPrefix matches Phase 2.5 topology hints (e.g.
// topology.vgpu.pranav2910.com/preferred-zone). These must also ride the
// Job → Claim → Slice chain so the scheduler sees them on the slice.
const topologyAnnotationPrefix = "topology.vgpu.pranav2910.com/"

// propagatedAnnotationPrefixes is the allow-list of annotation prefixes that
// cross object boundaries on derived objects. Everything else (kubectl
// bookkeeping, last-applied-config, etc.) is intentionally dropped.
var propagatedAnnotationPrefixes = []string{gangAnnotationPrefix, topologyAnnotationPrefix}

// FilterGangAnnotations returns a new map containing only the annotations from
// src whose key matches one of propagatedAnnotationPrefixes. Returns nil if
// there are none, so the caller can omit the Annotations field entirely on
// derived objects rather than carrying an empty map.
func FilterGangAnnotations(src map[string]string) map[string]string {
	if len(src) == 0 {
		return nil
	}
	out := make(map[string]string, len(src))
	for k, v := range src {
		for _, prefix := range propagatedAnnotationPrefixes {
			if strings.HasPrefix(k, prefix) {
				out[k] = v
				break
			}
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
