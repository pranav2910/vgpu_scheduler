package security

import (
	"context"
	"strings"

	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// ExtractTenant extracts the namespace as the primary multi-tenant boundary.
func ExtractTenant(ctx context.Context, req admission.Request) string {
	// In an enterprise setup, this would integrate with OIDC or SPIFFE
	return strings.TrimSpace(req.Namespace)
}
