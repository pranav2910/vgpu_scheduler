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

	// Bug #16: start the webhook server on :9443, reading TLS material from
	// the cert-manager-provisioned secret mounted at /tmp/k8s-webhook-server/serving-certs.
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: ":8080"},
		HealthProbeBindAddress: ":8082",
		LeaderElection:         true,
		LeaderElectionID:       "vgpu-controller-lock",
		WebhookServer: webhookserver.NewServer(webhookserver.Options{
			Port:    9443,
			CertDir: "/tmp/k8s-webhook-server/serving-certs",
		}),
	})
	if err != nil {
		log.Fatalf("creating manager: %v", err)
	}

	// Reconcilers.
	if err := (&controller.VGPUClaimReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUClaim reconciler: %v", err)
	}

	// Layer 2 Phase 2.1a: VGPUJobReconciler manages workload-intent jobs.
	if err := (&controller.VGPUJobReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUJobReconciler: %v", err)
	}
	if err := (&controller.VGPUSliceReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		log.Fatalf("setting up VGPUSlice reconciler: %v", err)
	}

	// Bug #16: register admission webhooks.
	decoder := admission.NewDecoder(scheme)
	mgr.GetWebhookServer().Register("/mutate-v1-pod",
		&webhookserver.Admission{Handler: webhook.NewPodMutatorHandler(mgr.GetClient(), decoder)})
	mgr.GetWebhookServer().Register("/validate-infrastructure-pranav2910-com-v1alpha1-vgpuclaim",
		&webhookserver.Admission{Handler: webhook.NewClaimValidatorHandler(decoder)})
	log.Println("Webhook server registered on :9443")

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
