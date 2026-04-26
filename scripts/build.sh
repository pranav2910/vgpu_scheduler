#!/bin/bash
set -e
echo "🔨 Building Binaries..."
go build -o bin/scheduler ./cmd/scheduler/main.go
go build -o bin/controller ./cmd/controller/main.go
go build -o bin/nodeagent ./cmd/nodeagent/main.go
echo "✅ Build Complete!"
