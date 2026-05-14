package controller

import "strings"

// gangAnnotationPrefix matches all annotations the gang scheduling feature
// stamps on its objects (gang reference, reservation reference, gang index,
// etc.). We propagate exactly these from Job → Claim → Slice; no other
// annotations cross object boundaries (avoids leaking kubectl bookkeeping,
// last-applied-config, etc. into derived objects).
const gangAnnotationPrefix = "gang.vgpu.pranav2910.com/"

// FilterGangAnnotations returns a new map containing only the gang-related
// annotations from src. Returns nil if there are no gang annotations to
// propagate, so the caller can omit the Annotations field entirely on
// derived objects rather than carrying an empty map.
func FilterGangAnnotations(src map[string]string) map[string]string {
	if len(src) == 0 {
		return nil
	}
	out := make(map[string]string, len(src))
	for k, v := range src {
		if strings.HasPrefix(k, gangAnnotationPrefix) {
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
