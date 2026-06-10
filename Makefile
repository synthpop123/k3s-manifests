# Operate the lkwplus.com k3s cluster from this Mac.
#
# Prereqs (one-time):
#   - kubectl + helm in PATH (brew install kubectl helm)
#   - kubeconfig pointing at k3s.lkwplus.com:6443  (kubectl get nodes works)
#   - SSH aliases arm/amd1/amd2/sg in ~/.ssh/config (see README)
#   - make repos        # add the helm repos platform/ needs
#   - cp .env.example .env && edit it
#
# Run `make` with no target for the list.

KUBECTL ?= kubectl
HELM    ?= helm

# Pinned upstream multica chart version; bump together with the image tags in
# apps/multica/values.yaml (see apps/multica/README.md).
MULTICA_CHART_VERSION ?= 0.3.18

# Pinned upstream supabase chart version. The chart pins every component image tag
# internally, so this single number controls the whole stack (see apps/supabase/README.md).
SUPABASE_CHART_VERSION ?= 0.5.6

# Pinned platform chart versions — same philosophy as the apps: a `make platform`
# re-run must never silently upgrade anything. Bump with `make bump APP=cert-manager`
# / `make bump APP=headlamp` (or edit here), review the diff, then re-run the target.
CERT_MANAGER_CHART_VERSION ?= v1.20.2
HEADLAMP_CHART_VERSION     ?= 0.42.0

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

# --- status -----------------------------------------------------------------
status: ## Nodes + all pods at a glance
	$(KUBECTL) get nodes -o wide
	@echo
	$(KUBECTL) get pods -A

# Drift check: what would change if every apply target ran right now. Nothing is applied.
# helm diff = desired (chart pin + values.yaml) vs the stored release; kubectl diff = file
# vs live object; the traefik line diffs the repo copy against the file scp'd onto ARM.
# kubectl/diff exit 1 just means "drift found", so it's tolerated; >1 is a real error.
diff: ## Preview drift between this repo and the live cluster (applies nothing)
	@echo '==> helm: cert-manager'
	$(HELM) diff upgrade cert-manager jetstack/cert-manager --install \
	  --version $(CERT_MANAGER_CHART_VERSION) --namespace cert-manager \
	  -f platform/cert-manager/values.yaml
	@echo '==> helm: headlamp'
	$(HELM) diff upgrade headlamp headlamp/headlamp --install \
	  --version $(HEADLAMP_CHART_VERSION) --namespace headlamp \
	  -f platform/headlamp/values.yaml
	@echo '==> helm: multica'
	$(HELM) diff upgrade multica oci://ghcr.io/multica-ai/charts/multica --install \
	  --version $(MULTICA_CHART_VERSION) --namespace multica \
	  -f apps/multica/values.yaml
	@echo '==> helm: supabase'
	$(HELM) diff upgrade supabase supabase/supabase --install \
	  --version $(SUPABASE_CHART_VERSION) --namespace supabase \
	  -f apps/supabase/values.yaml
	@echo '==> plain manifests'
	$(KUBECTL) diff -f platform/cert-manager/clusterissuer-letsencrypt-cf.yaml || [ $$? -eq 1 ]
	$(KUBECTL) diff -f platform/headlamp/headlamp-login.yaml || [ $$? -eq 1 ]
	$(KUBECTL) diff -f apps/multica/certificate.yaml || [ $$? -eq 1 ]
	$(KUBECTL) diff -f apps/multica/backup.yaml || [ $$? -eq 1 ]
	$(KUBECTL) diff -f apps/supabase/backup.yaml || [ $$? -eq 1 ]
	@for d in apps/*/; do \
	  if [ -f "$$d/kustomization.yaml" ]; then \
	    echo "==> kustomize app: $$d"; \
	    $(KUBECTL) diff -k "$$d" || [ $$? -eq 1 ] || exit $$?; \
	  fi; \
	done
	@echo '==> traefik HelmChartConfig (file on ARM)'
	ssh arm cat /var/lib/rancher/k3s/server/manifests/traefik-config.yaml \
	  | diff platform/traefik/traefik-helmchartconfig.yaml - || [ $$? -eq 1 ]
	@echo 'diff done — empty sections above mean no drift.'

# --- one-time setup ---------------------------------------------------------
repos: ## Add/refresh the helm repos + helm-diff plugin used by this repo (run once per machine)
	$(HELM) repo add jetstack https://charts.jetstack.io
	$(HELM) repo add headlamp https://kubernetes-sigs.github.io/headlamp/
	$(HELM) repo add supabase https://supabase-community.github.io/supabase-kubernetes
	$(HELM) repo update
	@$(HELM) plugin list | grep -q '^diff' \
	  || $(HELM) plugin install --verify=false https://github.com/databus23/helm-diff  # helm-diff ships no provenance (helm >=4 verifies by default)

secrets: ## Create/rotate in-cluster Secrets from .env (all apps; or one: APP=cert-manager|wallos|multica|supabase)
	./scripts/apply-secrets.sh $(APP)

secrets-platform: ## Create just the platform Secrets (cloudflare-api-token for cert-manager)
	./scripts/apply-secrets.sh cert-manager

# --- platform components ----------------------------------------------------
cert-manager: ## Upgrade/install cert-manager (pinned chart) + its ClusterIssuer
	$(HELM) upgrade --install cert-manager jetstack/cert-manager \
	  --version $(CERT_MANAGER_CHART_VERSION) \
	  --namespace cert-manager --create-namespace \
	  -f platform/cert-manager/values.yaml --wait
	$(KUBECTL) apply -f platform/cert-manager/clusterissuer-letsencrypt-cf.yaml

headlamp: ## Upgrade/install Headlamp (pinned chart) + its admin login
	$(HELM) upgrade --install headlamp headlamp/headlamp \
	  --version $(HEADLAMP_CHART_VERSION) \
	  --namespace headlamp --create-namespace \
	  -f platform/headlamp/values.yaml --wait
	$(KUBECTL) apply -f platform/headlamp/headlamp-login.yaml

traefik: ## Push the Traefik ARM-pin config to the server node (k3s auto-deploys it)
	scp platform/traefik/traefik-helmchartconfig.yaml \
	  arm:/var/lib/rancher/k3s/server/manifests/traefik-config.yaml

platform: repos secrets-platform cert-manager headlamp traefik ## Bootstrap/refresh ALL platform components (correct order)

# --- node config ------------------------------------------------------------
# node-config/*.config.yaml are templates: __NODE_IP__ is filled at apply time from
# the matching NODE_IP_* variable in .env (public IPs stay out of git) and the
# rendered file is streamed straight onto the node — nothing is written locally.
node-config: ## Render node-config/<NODE>.config.yaml from .env, push & restart k3s (NODE=arm|amd1|amd2|sg)
	@test -n "$(NODE)" || { echo "usage: make node-config NODE=arm|amd1|amd2|sg"; exit 1; }
	@test -f .env || { echo "ERROR: .env not found (cp .env.example .env and fill NODE_IP_*)"; exit 1; }
	@var="NODE_IP_$$(echo $(NODE) | tr a-z A-Z)"; \
	ip="$$(sed -n "s/^$$var=//p" .env | tail -1)"; \
	test -n "$$ip" || { echo "ERROR: $$var is not set in .env"; exit 1; }; \
	ssh $(NODE) 'mkdir -p /etc/rancher/k3s' && \
	sed "s/__NODE_IP__/$$ip/" node-config/$(NODE).config.yaml | ssh $(NODE) 'cat > /etc/rancher/k3s/config.yaml' && \
	ssh $(NODE) 'systemctl restart $(if $(filter arm,$(NODE)),k3s,k3s-agent)'

# --- apps -------------------------------------------------------------------
app: ## Deploy/update an app folder (APP=<name> -> kubectl apply -k apps/<name>/)
	@test -n "$(APP)" || { echo "usage: make app APP=<name>"; exit 1; }
	$(KUBECTL) apply -k apps/$(APP)/

bump: ## Show or pin a version (APP=<name> [VERSION=x.y.z]); kustomize image, multica, or a Makefile chart pin; no apply
	@test -n "$(APP)" || { echo "usage: make bump APP=<name> [VERSION=x.y.z]"; exit 1; }
	./scripts/bump-app-image.sh $(APP) $(VERSION)

app-pull: ## Restart an app & re-pull its image (APP=<name>); pinned apps upgrade via 'make bump'
	@test -n "$(APP)" || { echo "usage: make app-pull APP=<name>"; exit 1; }
	$(KUBECTL) -n $(APP) rollout restart deploy/$(APP)
	$(KUBECTL) -n $(APP) rollout status deploy/$(APP)

multica: ## Install/upgrade multica via Helm + its TLS cert + backup CronJob (run `make secrets` first)
	$(KUBECTL) create namespace multica --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f apps/multica/certificate.yaml
	$(KUBECTL) apply -f apps/multica/backup.yaml
	$(HELM) upgrade --install multica oci://ghcr.io/multica-ai/charts/multica \
	  --version $(MULTICA_CHART_VERSION) --namespace multica \
	  -f apps/multica/values.yaml --wait --timeout 10m

supabase: ## Install/upgrade Supabase via Helm + backup CronJob (run `make repos` + `make secrets` first)
	$(KUBECTL) create namespace supabase --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f apps/supabase/backup.yaml
	$(HELM) upgrade --install supabase supabase/supabase \
	  --version $(SUPABASE_CHART_VERSION) --namespace supabase \
	  -f apps/supabase/values.yaml --timeout 15m

# --- backups ----------------------------------------------------------------
backup-now: ## Run an app's nightly R2 backup right now (APP=wallos|multica|supabase) and show its log
	@test -n "$(APP)" || { echo "usage: make backup-now APP=wallos|multica|supabase"; exit 1; }
	@job="$(APP)-backup-manual-$$(date +%H%M%S)"; \
	$(KUBECTL) -n $(APP) create job --from=cronjob/$(APP)-backup "$$job" && \
	$(KUBECTL) -n $(APP) wait --for=condition=complete --timeout=15m "job/$$job" && \
	$(KUBECTL) -n $(APP) logs "job/$$job" --all-containers --prefix

# --- misc -------------------------------------------------------------------
headlamp-token: ## Print the Headlamp admin login token
	@$(KUBECTL) -n headlamp get secret headlamp-login-token -o jsonpath='{.data.token}' | base64 -d; echo

.PHONY: help status diff repos secrets secrets-platform cert-manager headlamp traefik platform node-config app app-pull bump multica supabase backup-now headlamp-token
