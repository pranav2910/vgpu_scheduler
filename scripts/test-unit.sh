#!/bin/bash
set -e
echo "🧪 Running Core Unit Tests..."
go test -v ./internal/scheduler/... ./internal/state/... ./internal/telemetry/...
