// Command gpu-probe is a standalone, no-Kubernetes smoke test for the GPU
// observation layer. It runs the exact same GPUProvider the node agent uses and
// prints what it reads, so you can validate the NVML path on real hardware
// (e.g. an RTX 3050 on Windows via `docker run --gpus all`) without standing up
// a cluster.
//
//	# fake provider (no GPU needed) — sanity:
//	go run ./cmd/gpu-probe
//	# real NVML:
//	go build -tags nvml -o gpu-probe ./cmd/gpu-probe && ./gpu-probe
//	# or in Docker (Windows/WSL2 friendly):
//	make docker-build-gpu-probe-nvml
//	docker run --rm --gpus all vgpu-gpu-probe:nvml
//
// Then compare against:
//
//	nvidia-smi --query-gpu=index,name,uuid,memory.total,memory.used,memory.free --format=csv
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/pranav2910/vgpu-scheduler/internal/nodeagent/gpu"
)

const miB = 1024 * 1024

func main() {
	provider, err := gpu.NewProvider()
	if err != nil {
		fmt.Fprintf(os.Stderr, "GPU provider init FAILED: %v\n", err)
		fmt.Fprintln(os.Stderr, "  → Is the NVIDIA driver present and libnvidia-ml.so.1 loadable?")
		fmt.Fprintln(os.Stderr, "  → In Docker, did you pass --gpus all (and is the NVIDIA container toolkit installed)?")
		os.Exit(1)
	}
	defer provider.Shutdown()

	fmt.Printf("vGPU NVML probe — provider=%s\n", provider.Name())

	devices, err := provider.ListDevices(context.Background())
	if err != nil {
		fmt.Fprintf(os.Stderr, "ListDevices FAILED: %v\n", err)
		os.Exit(1)
	}
	if len(devices) == 0 {
		fmt.Fprintln(os.Stderr, "no GPUs reported")
		os.Exit(1)
	}

	healthy := 0
	for _, d := range devices {
		status := "healthy"
		if !d.Healthy {
			status = "UNHEALTHY: " + d.Error
		} else {
			healthy++
		}
		fmt.Printf("\nGPU %d: %s\n", d.Index, d.Name)
		fmt.Printf("  UUID:   %s\n", d.UUID)
		fmt.Printf("  total:  %5d MiB (%d bytes)\n", d.TotalMemoryBytes/miB, d.TotalMemoryBytes)
		fmt.Printf("  used:   %5d MiB (%d bytes)\n", d.UsedMemoryBytes/miB, d.UsedMemoryBytes)
		fmt.Printf("  free:   %5d MiB (%d bytes)\n", d.FreeMemoryBytes/miB, d.FreeMemoryBytes)
		fmt.Printf("  health: %s\n", status)
	}

	fmt.Printf("\n%d device(s), %d healthy. Compare UUID/total/used/free against:\n", len(devices), healthy)
	fmt.Println("  nvidia-smi --query-gpu=index,name,uuid,memory.total,memory.used,memory.free --format=csv")

	if provider.Name() == "nvml" && healthy == 0 {
		os.Exit(1)
	}
}
