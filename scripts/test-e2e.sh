#!/bin/bash
set -e
echo "🌐 Running End-to-End Cluster Tests..."
echo "Applying mock hardware..."
./scripts/persistent-mock.sh &
MOCK_PID=$!
go test -v ./test/e2e/...
kill $MOCK_PID
