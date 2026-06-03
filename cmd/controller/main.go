package main

import (
	"log"
	"os"

	vgpuv1alpha1 "github.com/pranav2910/vgpu-scheduler/api/v1alpha1"
	"github.com/pranav2910/vgpu-scheduler/internal/controller"
	"github.com/pranav2910/vgpu-scheduler/internal/webhook"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	webhookserver "sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

func main() {

	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("ENV") != "production")))
	log.Println("Booting vGPU Controller...")

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		log.Fatalf("registering client-go scheme: %v", err)
	}
	if err := vgpuv1alpha1.AddToScheme(scheme); err != nil {
		log.Fatalf("registering vgpu scheme: %v", err)
	}

	cfg, err := ctrl.GetConfig()
	if err != nil {
		log.Fatalf("getting kubeconfig: %v", err)
	}

	// Webhooks require cert-manager-provisioned TLS at the mounted cert dir. They
	// can be disabled (VGPU_DISABLE_WEBHOOKS=true) to run the controller in a
	// minimal, reconcilers-only mode without cert-manager — used by the runtime-
	// feedback hardware E2E. Production leaves them on (the default).
	webhooksEnabled := os.Getenv("VGPU_DISABLE_WEBHOOKS") != "true"

	// Bug #16: start the webhook server on :9443, reading TLS material from
	// the cert-manager-provisioned secret mounted at /tmp/k8s-webhook-server/serving-certs.
	mgrOpts := ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: ":8080"},
		HealthProbeBindAddress: ":8082",
		LeaderElection:         true,
		LeaderElectionID:       "vgpu-controller-lock",
		// Release the lease on graceful shutdown so the standby takes over in
		// seconds rather than waiting out the lease duration. Phase 3.3.
		LeaderElectionReleaseOnCancel: true,
	}
	if webhooksEnabled {
		mgrOpts.WebhookServer = webhookserver.NewServer(webhookserver.Options{
			Port:    9443,
			CertDir: "/tmp/k8s-webhook-server/serving-certs",
		})
	}
	mgr, err := ctrl.NewManager(cfg, mgrOpts)
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	// Reconcilers.
	if err := (&controller.VGPUClaimReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUClaim reconciler: %v", err)
	}

	// Layer 2 Phase 2.1a: VGPUJobReconciler manages workload-intent jobs.
	// Phase 3.6: also emits the non-blocking VRAM-rightsizing advisory.
	if err := (&controller.VGPUJobReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("vgpu-controller"),
	}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUJobReconciler: %v", err)
	}

	// Layer 2 Phase 2.2a: VGPUQuotaReconciler refreshes namespace usage every 30s.
	if err := (&controller.VGPUQuotaReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUQuotaReconciler: %v", err)
	}
	if err := (&controller.VGPUSliceReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUSlice reconciler: %v", err)
	}

	// Layer 2 Phase 2.4a: gang scheduling.
	if err := (&controller.VGPUGangJobReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUGangJobReconciler: %v", err)
	}
	if err := (&controller.VGPUGangReservationReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUGangReservationReconciler: %v", err)
	}

	// Phase 3.5: Runtime Feedback Engine — aggregate per-slice runtime stats into
	// per-workload VGPUWorkloadProfiles (peak/avg, incident counts, recommended
	// VRAM, confidence). Observe-only; does not affect scheduling.
	if err := (&controller.VGPUWorkloadProfileReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUWorkloadProfileReconciler: %v", err)
	}

	// Bug #16: register admission webhooks (unless disabled for minimal mode).
	if webhooksEnabled {
		decoder := admission.NewDecoder(scheme)
		mgr.GetWebhookServer().Register("/mutate-v1-pod",
			&webhookserver.Admission{Handler: webhook.NewPodMutatorHandler(mgr.GetClient(), decoder)})
		mgr.GetWebhookServer().Register("/validate-infrastructure-pranav2910-com-v1alpha1-vgpuclaim",
			&webhookserver.Admission{Handler: webhook.NewClaimValidatorHandler(decoder)})
		mgr.GetWebhookServer().Register("/validate-infrastructure-pranav2910-com-v1alpha1-vgpugangjob",
			&webhookserver.Admission{Handler: webhook.NewGangJobValidatorHandler(decoder)})
		log.Println("Webhook server registered on :9443")
	} else {
		log.Println("Webhooks DISABLED (VGPU_DISABLE_WEBHOOKS=true) — reconcilers-only mode, no cert-manager required")
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Fatalf("adding healthz: %v", err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Fatalf("adding readyz: %v", err)
	}

	log.Println("Controller initialised. Watching claims and slices...")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Fatalf("controller manager crashed: %v", err)
	}
}
