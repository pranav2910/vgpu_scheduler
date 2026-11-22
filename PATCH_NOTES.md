# Applied vGPU scheduler bugfix patch

This script applied the following fixes:

1. Changed `go.mod` from Go 1.25 to Go 1.22-compatible dependencies.
2. Made NVML allocator fail closed when real allocation is not implemented.
3. Added explicit mock-mode helper for nodeagent startup.
4. Added allocator dependency injection helper for nodeagent manager.
5. Replaced checkpoint writes with atomic write/rename logic.
6. Rebuilt scheduler cache accounting to avoid double-counting after restarts.
7. Patched scheduler binding order where possible: `spec.nodeName` before `status.phase=Scheduled`.
8. Added safer cache sync for Ready/Released transitions.

Next commands:

```bash
go mod tidy
gofmt -w go.mod cmd internal api 2>/dev/null || gofmt -w $(find . -name '*.go')
go test ./...
```

If `cmd/nodeagent/main.go` or `internal/nodeagent/manager.go` had a different structure, inspect those files manually and wire `explicitMockMode()` into the allocator creation.
