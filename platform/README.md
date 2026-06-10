# platform

Cluster-wide infrastructure. These are installed **once** to bootstrap the cluster;
they rarely change. Two mechanisms are in play:

- **Helm releases** (`cert-manager`, `headlamp`) — managed with `helm`, configured by
  the `values.yaml` files here.
- **Plain manifests** (`ClusterIssuer`, `headlamp-login`) — applied with `kubectl apply -f`.
- **Traefik** — configured via a `HelmChartConfig` that lives in the k3s auto-deploy
  directory on ARM (see `traefik/traefik-helmchartconfig.yaml`), not via kubectl.

## Bootstrap order (rebuild from scratch)

> Assumes k3s is already installed on all nodes (see the repo root README),
> and the one-time setup from the root README is done (`brew install kubectl helm`,
> `make repos`, `cp .env.example .env` + fill in).

The whole platform, in the correct order, is one command:

```bash
make platform
```

It runs `repos` → `secrets-platform` (just the Cloudflare token — platform bootstrap
needs no app secrets) → `cert-manager` (chart + ClusterIssuer) → `headlamp` (chart +
admin login) → `traefik`. The ordering matters: the Cloudflare Secret must exist
before the ClusterIssuer, and the cert-manager CRDs before the ClusterIssuer is applied.
Both chart versions are pinned in the root [`Makefile`](../Makefile)
(`CERT_MANAGER_CHART_VERSION` / `HEADLAMP_CHART_VERSION`), so re-running never
silently upgrades anything.

<details>
<summary>The equivalent raw commands</summary>

```bash
# 0) helm repos + the helm-diff plugin (once per machine)
helm repo add jetstack https://charts.jetstack.io
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
helm plugin install --verify=false https://github.com/databus23/helm-diff

# 1) Cloudflare API token Secret (real value from .env, never committed)
#    cp .env.example .env && edit .env, then:
./scripts/apply-secrets.sh cert-manager

# 2) cert-manager chart (version = CERT_MANAGER_CHART_VERSION in the Makefile) + ClusterIssuer
helm upgrade --install cert-manager jetstack/cert-manager --version v1.20.2 \
  --namespace cert-manager --create-namespace -f platform/cert-manager/values.yaml --wait
kubectl apply -f platform/cert-manager/clusterissuer-letsencrypt-cf.yaml

# 3) Headlamp chart (version = HEADLAMP_CHART_VERSION in the Makefile) + admin login
helm upgrade --install headlamp headlamp/headlamp --version 0.42.0 \
  --namespace headlamp --create-namespace -f platform/headlamp/values.yaml --wait
kubectl apply -f platform/headlamp/headlamp-login.yaml

# 4) Traefik -> pin to ARM (copy into k3s auto-deploy dir on ARM)
scp platform/traefik/traefik-helmchartconfig.yaml \
    arm:/var/lib/rancher/k3s/server/manifests/traefik-config.yaml
```
</details>

## Update a component later

Edit its `values.yaml` (preview with `make diff`), then re-run the same target —
`helm upgrade --install` is idempotent:

```bash
make cert-manager     # or: make headlamp
```

To move to a newer chart, `make bump APP=cert-manager` (or `APP=headlamp`) lists the
published versions and pins one into the Makefile; review the diff, then re-run the
target.
