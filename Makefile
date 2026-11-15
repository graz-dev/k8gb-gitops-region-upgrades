SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Pinned k8gb commit (we never modify ./k8gb/).
K8GB_REF ?= 901a4f2aa0ad7bba3350623b02f9effd6726d8b1
K8GB_REPO ?= https://github.com/k8gb-io/k8gb

# Host ports bound by k8gb's local setup; the mgmt cluster must not use them.
K8GB_HOST_PORTS := 80 81 82 443 444 445 1053 3000 5053 5054 5055 8000 8001 8002 8080 8081 8082 9090 9091 9092
CLUSTERS_NUMBER ?= 3
export CLUSTERS_NUMBER
MIN_DOCKER_MEM_GB ?= 13
MIN_DOCKER_DISK_FREE_GB ?= 40

.DEFAULT_GOAL := help
.PHONY: help
help: ## Show targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

# ---------------------------------------------------------------- M0: base ---

.PHONY: k8gb-fetch
k8gb-fetch: ## Clone k8gb at the pinned commit into ./k8gb
	@[ -d k8gb/.git ] || git clone $(K8GB_REPO) k8gb
	@git -C k8gb cat-file -e $(K8GB_REF)^{commit} 2>/dev/null || git -C k8gb fetch --unshallow origin 2>/dev/null || git -C k8gb fetch origin
	@git -C k8gb checkout -q $(K8GB_REF)
	@echo "k8gb @ $$(git -C k8gb rev-parse --short HEAD)"

.PHONY: preflight
preflight: ## Check tools, Docker memory and free host ports
	@for t in docker k3d kubectl helm git dig curl jq yq htpasswd openssl; do \
	  command -v $$t >/dev/null || { echo "missing tool: $$t"; exit 1; }; done
	@mem=$$(docker info --format '{{.MemTotal}}'); \
	  gb=$$(( mem / 1024 / 1024 / 1024 )); \
	  [ $$gb -ge $(MIN_DOCKER_MEM_GB) ] || echo "WARNING: Docker has ~$${gb} GB, plan for $(MIN_DOCKER_MEM_GB)+ GB"
	@# The k3s kubelets evict pods when the Docker disk is over 85% full (DiskPressure): the Kubernetes
	@# upgrade pods get evicted and nothing completes. Colima: `colima start --disk 140` makes it bigger.
	@free=$$(docker run --rm -v /var/lib/docker:/d alpine df -Pk /d 2>/dev/null | awk 'NR==2{print int($$4/1024/1024)}'); \
	  [ -z "$$free" ] || [ "$$free" -ge $(MIN_DOCKER_DISK_FREE_GB) ] || echo "WARNING: only $${free} GB free for Docker, plan for $(MIN_DOCKER_DISK_FREE_GB)+ GB (kubelet DiskPressure evicts the upgrade pods)"
	@busy=""; for p in $(K8GB_HOST_PORTS); do \
	  lsof -nP -iTCP:$$p -sTCP:LISTEN >/dev/null 2>&1 && busy="$$busy $$p"; done; \
	  [ -z "$$busy" ] || { echo "host ports already in use:$$busy"; exit 1; }
	@# Four k3s clusters exhaust the default inotify limit (128 instances) and
	@# containerd then fails with "too many open files". Colima VMs only; not
	@# persistent across a VM restart, so it is (re)applied here.
	@if command -v colima >/dev/null && colima status >/dev/null 2>&1; then \
	  colima ssh -- sudo sysctl -q -w fs.inotify.max_user_instances=2048 fs.inotify.max_user_watches=1048576; fi
	@echo "preflight ok"

.PHONY: base-up
base-up: preflight k8gb-fetch ## k8gb clusters (edgedns + 3 regions eu/us/cz, k3s v1.35) with k8gb, no test apps
	./scripts/base-up.sh

.PHONY: base-check
base-check: ## M0: query the edge DNS and list k8gb/Istio pods
	dig @127.0.0.1 -p 1053 podinfo.cloud.example.com +tcp +noall +comments | grep status
	kubectl --context k3d-test-gslb1 get pods -A | grep -E 'k8gb|istio'
	kubectl --context k3d-test-gslb2 get pods -A | grep -E 'k8gb|istio'

.PHONY: base-down
base-down: ## Remove the k8gb clusters
	$(MAKE) -C k8gb CLUSTERS_NUMBER=$(CLUSTERS_NUMBER) destroy-full-local-setup

# ------------------------------------------------------------- M1: GitOps ---

.PHONY: tools-image
tools-image: ## Build the dig/curl/jq toolbox image and load it into mgmt
	docker build -q -t demo-tools:local tools/
	k3d image import demo-tools:local -c mgmt

.PHONY: bootstrap
bootstrap: ## mgmt cluster with cert-manager, Argo CD, Gitea, Kargo
	./scripts/bootstrap.sh

.PHONY: wire
wire: ## Register regions in Argo CD, seed the Git repo, create the Applications, first sync
	./scripts/register-clusters.sh
	./scripts/seed-git.sh
	kubectl --context k3d-mgmt apply -f gitops/argocd/
	@until [ "$$(kubectl --context k3d-mgmt -n argocd get applications --no-headers 2>/dev/null | wc -l)" -ge 9 ]; do sleep 2; done
	./scripts/sync.sh podinfo-eu podinfo-us podinfo-cz gslb-eu gslb-us gslb-cz
	@# The first sync of the Plans restarts each region's nodes (the Applications sync by themselves, all
	@# three at about the same time), and Docker may hand the restarted containers other addresses:
	@# refresh-addresses re-learns whatever moved (see NOTES.md). It also needs free disk in the VM:
	@# below 15% free the kubelet evicts the upgrade pods and the Plans never complete.
	./scripts/sync.sh k8s-eu k8s-us k8s-cz
	./scripts/refresh-addresses.sh

.PHONY: kargo
kargo: ## Kargo: shared task and verification templates, the kubernetes pipeline
	./scripts/kargo-apply.sh

.PHONY: up
up: base-up bootstrap tools-image wire kargo freight-sync ready ## Everything, from nothing to ready to demo

.PHONY: ready
ready: ## Re-learn container addresses, then wait until every Application is healthy and the edge DNS answers for all three regions
	./scripts/refresh-addresses.sh
	./scripts/wait-ready.sh

# ------------------------------------------------------------------- demo ---

.PHONY: watch
watch: ## Live view: which regions are in DNS, who answers, versions, errors
	./scripts/watch.sh

.PHONY: drain
drain: ## Manual drain without Kargo: make drain REGION=eu [RECEIVER=us]
	./scripts/rotation.sh drain $(REGION) $(RECEIVER)

.PHONY: restore
restore: ## Manual restore without Kargo: make restore REGION=eu
	./scripts/rotation.sh restore $(REGION)

.PHONY: freight
freight: ## The Freight list: the k3s versions you can roll out (the "new version available" notification)
	./scripts/freight.sh
	@echo; ./scripts/freight.sh discovered

.PHONY: freight-sync
freight-sync: ## Create a Freight for the newest patch of every minor the Warehouse discovered (1.35, 1.36, 1.37, ...)
	./scripts/freight.sh sync
	@echo; ./scripts/freight.sh

.PHONY: demo-kubernetes
demo-kubernetes: ## Upgrade Kubernetes one region at a time (eu, us, cz): make demo-kubernetes VERSION=v1.36.6-k3s1
	./scripts/rollout.sh kubernetes $(VERSION)

.PHONY: demo-kubernetes-nodrain
demo-kubernetes-nodrain: ## CONTROL: the same upgrade of one region WITHOUT draining it: make demo-kubernetes-nodrain REGION=eu VERSION=v1.36.6-k3s1
	./scripts/k8s-nodrain.sh $(REGION) $(VERSION)

.PHONY: demo-kubernetes-bad
demo-kubernetes-bad: ## FAILURE PATH: an upgrade that cannot complete (a k3s build that does not exist); the region stays drained: make demo-kubernetes-bad [REGION=eu]
	./scripts/rollout.sh kubernetes $$(./scripts/bad-k3s-freight.sh create $(or $(REGION),eu)) $(or $(REGION),eu)
	@echo; echo "$(or $(REGION),eu) stays drained, the other regions keep serving. Clean up and fix it: see DEMO.md, then make demo-kubernetes-fix"

.PHONY: demo-kubernetes-fix
demo-kubernetes-fix: ## After demo-kubernetes-bad and the clean-up in DEMO.md: roll the real version through the region again: make demo-kubernetes-fix [REGION=eu]
	./scripts/retry-from-upgrade.sh $(or $(REGION),eu) $$(./scripts/bad-k3s-freight.sh good $(or $(REGION),eu))

.PHONY: status
status: ## Status of the kubernetes pipeline
	./scripts/pipeline-status.sh kubernetes

.PHONY: ui-argocd
ui-argocd: ## Argo CD UI on http://localhost:8081 (user admin)
	@echo "password: $$(kubectl --context k3d-mgmt -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	kubectl --context k3d-mgmt -n argocd port-forward svc/argocd-server 8081:80

.PHONY: ui-kargo
ui-kargo: ## Kargo UI on https://localhost:8082 (user admin)
	@echo "password: $$(cat .secrets/kargo-admin-password)"
	kubectl --context k3d-mgmt -n kargo port-forward svc/kargo-api 8082:443

# --------------------------------------------------------------- teardown ---

.PHONY: down
down: ## Remove EVERYTHING this repo created, including the k8gb clusters
	-k3d cluster delete mgmt
	-docker rm -f demo-watch
	-$(MAKE) -C k8gb CLUSTERS_NUMBER=$(CLUSTERS_NUMBER) destroy-full-local-setup
	-docker network rm k3d-action-bridge-network
	-docker rmi demo-tools:local
	rm -rf .secrets .logs

.PHONY: reset
reset: ## Reset rotation + Kargo to the starting state (the Kubernetes version is kept: use `make down up` to start again from 1.35)
	KEEP_VERSIONS=1 ./scripts/seed-git.sh
	./scripts/sync.sh gslb-eu gslb-us gslb-cz
	-kubectl --context k3d-mgmt delete project kubernetes --ignore-not-found --wait=true
	-kubectl --context k3d-mgmt wait --for=delete namespace/kubernetes --timeout=180s
	./scripts/kargo-apply.sh
