package security

import (
	"fmt"

	corev1 "k8s.io/api/core/v1"
)

// Dangerous capabilities that grant equivalent power to privileged: true.
var dangerousCapabilities = map[corev1.Capability]bool{
	"SYS_ADMIN":       true,
	"SYS_PTRACE":      true,
	"SYS_MODULE":      true,
	"SYS_RAWIO":       true,
	"DAC_READ_SEARCH": true,
	"BPF":             true,
	"ALL":             true,
}

// ValidatePodSecurity ensures no workload can bypass the CDI hardware isolation.
func ValidatePodSecurity(pod *corev1.Pod) error {
	// 1. Prevent host namespace sharing.
	if pod.Spec.HostIPC || pod.Spec.HostPID || pod.Spec.HostNetwork {
		return fmt.Errorf("security violation: vGPU pods cannot use HostIPC, HostPID, or HostNetwork")
	}

	// 2. Container-level checks.
	allContainers := append([]corev1.Container{}, pod.Spec.Containers...)
	allContainers = append(allContainers, pod.Spec.InitContainers...)

	for _, c := range allContainers {
		sc := c.SecurityContext
		if sc == nil {
			continue
		}
		if sc.Privileged != nil && *sc.Privileged {
			return fmt.Errorf("security violation: container %q cannot run as privileged", c.Name)
		}
		// Bug #29: AllowPrivilegeEscalation and HostProcess.
		if sc.AllowPrivilegeEscalation != nil && *sc.AllowPrivilegeEscalation {
			return fmt.Errorf("security violation: container %q sets allowPrivilegeEscalation=true", c.Name)
		}
		if sc.WindowsOptions != nil && sc.WindowsOptions.HostProcess != nil && *sc.WindowsOptions.HostProcess {
			return fmt.Errorf("security violation: container %q uses Windows hostProcess", c.Name)
		}
		// Bug #29: procMount Unmasked.
		if sc.ProcMount != nil && *sc.ProcMount != corev1.DefaultProcMount {
			return fmt.Errorf("security violation: container %q uses non-default procMount %q", c.Name, *sc.ProcMount)
		}
		// Bug #29: dangerous capabilities.
		if sc.Capabilities != nil {
			for _, cap := range sc.Capabilities.Add {
				if dangerousCapabilities[cap] {
					return fmt.Errorf("security violation: container %q adds dangerous capability %q", c.Name, cap)
				}
			}
		}
	}

	// 3. No hostPath volumes.
	for _, vol := range pod.Spec.Volumes {
		if vol.HostPath != nil {
			return fmt.Errorf("security violation: vGPU pods cannot mount arbitrary hostPaths")
		}
	}
	return nil
}
