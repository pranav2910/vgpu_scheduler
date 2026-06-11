//go:build nvml

package nvml

import (
	"fmt"

	nvmllib "github.com/NVIDIA/go-nvml/pkg/nvml"
)

// enumerateDevices returns every usable physical GPU on the node with the
// memory figures best-fit placement needs (M-GPU: multi-card nodes). Compiled
// only with -tags nvml; this is the sole place the allocator touches the
// NVIDIA driver. Init/Shutdown are balanced and NVML's init is ref-counted,
// so this is safe alongside the long-lived observation provider's session.
//
// A single sick card is SKIPPED (logged by the caller via the ledger's view),
// not fatal — one bad device must not stop allocation on its seven healthy
// neighbors. A card whose UUID cannot be read is also skipped: the ledger
// cannot safely account a card it cannot identify.
func enumerateDevices() ([]allocDevice, error) {
	if ret := nvmllib.Init(); ret != nvmllib.SUCCESS {
		return nil, fmt.Errorf("nvml init: %s", nvmllib.ErrorString(ret))
	}
	defer nvmllib.Shutdown()

	count, ret := nvmllib.DeviceGetCount()
	if ret != nvmllib.SUCCESS {
		return nil, fmt.Errorf("nvml device count: %s", nvmllib.ErrorString(ret))
	}

	devices := make([]allocDevice, 0, count)
	for i := 0; i < count; i++ {
		handle, ret := nvmllib.DeviceGetHandleByIndex(i)
		if ret != nvmllib.SUCCESS {
			continue
		}
		uuid, ret := handle.GetUUID()
		if ret != nvmllib.SUCCESS || uuid == "" {
			continue
		}
		// Prefer GetMemoryInfo_v2 (separates driver-Reserved from Used). Fall
		// back to v1, where reserved stays 0 — that overstates availability by
		// the driver reserve (~hundreds of MiB), acceptable slack on cards
		// packed in multi-GiB slices.
		var total, reserved int64
		if mem2, ret := handle.GetMemoryInfo_v2(); ret == nvmllib.SUCCESS && mem2.Total > 0 {
			total, reserved = int64(mem2.Total), int64(mem2.Reserved)
		} else if mem, ret := handle.GetMemoryInfo(); ret == nvmllib.SUCCESS {
			total = int64(mem.Total)
		} else {
			continue
		}
		devices = append(devices, allocDevice{uuid: uuid, total: total, reserved: reserved})
	}
	if len(devices) == 0 {
		return nil, fmt.Errorf("no usable GPUs enumerated (of %d reported)", count)
	}
	return devices, nil
}
