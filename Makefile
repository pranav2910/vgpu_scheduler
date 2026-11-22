# vGPU Scheduler Makefile
# Run `make help` for a list of targets.

IMG_CONTROLLER ?= vgpu-controller:latest
IMG_NODEAGENT  ?= vgpu-nodeagent:latest
IMG_SCHEDULER  ?= vgpu-scheduler:latest
NAMESPACE      ?= vgpu-system
MANIFESTS      := deployments/manifests

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: fmt
fmt: ## go fmt
	go fmt ./...

.PHONY: vet
vet: ## go vet
	go vet ./...

.PHONY: test
test: fmt vet ## Run unit + integration tests
	go test ./...

.PHONY: build
build: fmt vet ## Build all three binaries
	go build -o bin/scheduler  ./cmd/scheduler/main.go
	go build -o bin/controller ./cmd/controller/main.go
	go build -o bin/nodeagent  ./cmd/nodeagent/main.go

.PHONY: docker-build
docker-build: ## Build all three container images (node agent: fake GPU provider)
	docker build -t $(IMG_SCHEDULER)  -f Dockerfile.scheduler .
	docker build -t $(IMG_CONTROLLER) -f Dockerfile.controller .
	docker build -t $(IMG_NODEAGENT)  -f Dockerfile.nodeagent .

IMG_NODEAGENT_NVML ?= vgpu-nodeagent:nvml
.PHONY: docker-build-nodeagent-nvml
docker-build-nodeagent-nvml: ## Build the node agent with the real NVML provider (for real GPU nodes / g5)
	docker build --build-arg GOTAGS=nvml -t $(IMG_NODEAGENT_NVML) -f Dockerfile.nodeagent .

IMG_GPU_PROBE_NVML ?= vgpu-gpu-probe:nvml
.PHONY: docker-build-gpu-probe-nvml
docker-build-gpu-probe-nvml: ## Build the standalone NVML probe (no k8s; run with: docker run --rm --gpus all $(IMG_GPU_PROBE_NVML))
	docker build --build-arg GOTAGS=nvml -t $(IMG_GPU_PROBE_NVML) -f Dockerfile.gpu-probe .

.PHONY: install-crds
install-crds: ## Install CRDs into the current cluster
	kubectl apply -f $(MANIFESTS)/crds/

.PHONY: uninstall-crds
uninstall-crds: ## Remove CRDs (will delete all custom resources)
	kubectl delete -f $(MANIFESTS)/crds/

# Shared control-plane apply, WITHOUT the node agent. Backends (scheduler,
# controller) go up BEFORE the webhooks: the mutating/validating configs are
# failurePolicy=Fail, so registering them before their backend exists — or on a
# cluster without cert-manager, where certificate.yaml fails and make aborts —
# would leave fail-closed webhooks with no server, rejecting every vGPU create
# cluster-wide (scan finding). Webhooks last means a partial failure still
# leaves a working control plane.
.PHONY: install-base
install-base: install-crds
	kubectl apply -f $(MANIFESTS)/namespace.yaml
	kubectl apply -f $(MANIFESTS)/rbac/
	kubectl apply -f $(MANIFESTS)/scheduler_deployment.yaml
	kubectl apply -f $(MANIFESTS)/controller_deployment.yaml
	@echo ""
	@echo ">> Applying admission webhooks (requires cert-manager for the CA)."
	@echo ">> If this step fails, the webhooks are fail-closed — remove them with:"
	@echo ">>   kubectl delete -f $(MANIFESTS)/webhooks/   (until cert-manager is installed)"
	kubectl apply -f $(MANIFESTS)/webhooks/

.PHONY: install
install: install-base ## Full install with the FAKE GPU agent (kind/CI/dev ONLY — fabricates GPUs)
	@echo ""
	@echo ">> WARNING: deploying the FAKE-GPU node agent (nodeagent_daemonset.yaml)."
	@echo ">> It fabricates an 80GiB GPU on every node and does NOT touch real hardware."
	@echo ">> On a real GPU cluster use:  make install-nvml"
	kubectl apply -f $(MANIFESTS)/nodeagent_daemonset.yaml

.PHONY: install-nvml
install-nvml: install-base ## Full install with the REAL NVML node agent (real GPU nodes)
	kubectl apply -f $(MANIFESTS)/nodeagent_daemonset_nvml.yaml

.PHONY: uninstall
uninstall: ## Tear down the control plane (keeps namespace and CRDs)
	-kubectl delete -f $(MANIFESTS)/nodeagent_daemonset.yaml
	-kubectl delete -f $(MANIFESTS)/nodeagent_daemonset_nvml.yaml
	-kubectl delete -f $(MANIFESTS)/controller_deployment.yaml
	-kubectl delete -f $(MANIFESTS)/scheduler_deployment.yaml
	-kubectl delete -f $(MANIFESTS)/webhooks/
	-kubectl delete -f $(MANIFESTS)/rbac/

.PHONY: undeploy
undeploy: uninstall uninstall-crds ## Complete removal (cert-manager not touched)
	-kubectl delete namespace $(NAMESPACE)

.PHONY: logs-scheduler
logs-scheduler: ## Tail scheduler logs
	kubectl -n $(NAMESPACE) logs -l control-plane=vgpu-scheduler -f --tail=100

.PHONY: logs-controller
logs-controller: ## Tail controller logs
	kubectl -n $(NAMESPACE) logs -l control-plane=vgpu-controller -f --tail=100

.PHONY: logs-nodeagent
logs-nodeagent: ## Tail nodeagent logs
	kubectl -n $(NAMESPACE) logs -l app=vgpu-nodeagent -f --tail=100
