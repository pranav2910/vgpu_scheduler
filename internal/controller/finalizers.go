package controller

import (
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const (
	SliceFinalizerName = "infrastructure.pranav2910.com/slice-cleanup"
	// ClaimFinalizerName blocks claim deletion until all derived slices have
	// completed their own cleanup. Bug #40 fix.
	ClaimFinalizerName = "infrastructure.pranav2910.com/claim-cleanup"
)

// EnsureFinalizer adds the finalizer if it doesn't exist.
func EnsureFinalizer(obj client.Object, finalizer string) bool {
	if !controllerutil.ContainsFinalizer(obj, finalizer) {
		controllerutil.AddFinalizer(obj, finalizer)
		return true // Indicates the object was mutated and needs to be updated
	}
	return false
}

// RemoveFinalizer removes the finalizer to allow Kubernetes to delete the object.
func RemoveFinalizer(obj client.Object, finalizer string) bool {
	if controllerutil.ContainsFinalizer(obj, finalizer) {
		controllerutil.RemoveFinalizer(obj, finalizer)
		return true // Indicates the object was mutated
	}
	return false
}
