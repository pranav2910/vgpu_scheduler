package telemetry

import (
	"context"
	"github.com/google/uuid"
)

type contextKey string

const traceIDKey contextKey = "vgpu-trace-id"

// WithNewTrace injects a fresh Correlation ID into the context.
func WithNewTrace(ctx context.Context) context.Context {
	traceID := uuid.New().String()
	return context.WithValue(ctx, traceIDKey, traceID)
}

// WithTrace injects an existing Correlation ID (e.g., from an API claim) into the context.
func WithTrace(ctx context.Context, traceID string) context.Context {
	return context.WithValue(ctx, traceIDKey, traceID)
}

// ExtractTrace retrieves the Correlation ID for structured logging.
func ExtractTrace(ctx context.Context) string {
	if traceID, ok := ctx.Value(traceIDKey).(string); ok {
		return traceID
	}
	return "no-trace"
}
