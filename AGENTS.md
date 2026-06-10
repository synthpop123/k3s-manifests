# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The version-controlled source-of-truth for the **lkwplus.com k3s cluster**: platform
components, deployed apps, per-node k3s settings, and a template for new apps. It contains
no application code — only YAML manifests, Helm `values.yaml`, k3s node config, and a few
shell scripts in `scripts/`. There is no build, test, or lint step.

## The mental model that matters

**This is a push-based workflow, not GitOps-pull.** The repo lives on your control machine
and on GitHub; changes are pushed *to* the cluster from the control machine over the public
API (`k3s.lkwplus.com:6443`). The cluster never reads GitHub. So:

- The node needs no clone of this repo and no git/`gh` auth.
- The repo is meant to be a **faithful mirror of live cluster state** — one `apps/`
  folder per actually-deployed app, nothing speculative. Don't add manifests for things
  that aren't applied. `make diff` verifies the mirror: it previews what every apply
  target would change (helm diff + kubectl diff + the scp'd traefik file) without
  applying anything.
- Editing a file here changes nothing until you run the corresponding apply command.

## Four different apply mechanisms (don't mix them up)

The directory a file lives in determines how it reaches the cluster:

| Path | Mechanism | How it's applied |
|---|---|---|
| `apps/<name>/` (kustomize apps, e.g. `wallos`) | Kustomize | `kubectl apply -k apps/<name>/` (`make app APP=<name>`) |
| `apps/multica/values.yaml`, `apps/supabase/values.yaml` | Helm | `helm upgrade --install <release> <chart> -n <ns> -f <values.yaml>` (`make multica` / `make supabase`) |
| `platform/cert-manager/values.yaml`, `platform/headlamp/values.yaml` | Helm | `helm upgrade <release> <chart> -n <ns> -f <values.yaml>` |
| `platform/cert-manager/clusterissuer-*.yaml`, `platform/headlamp/headlamp-login.yaml` | Plain manifest | `kubectl apply -f <file>` |
| `platform/traefik/traefik-helmchartconfig.yaml` | k3s auto-deploy | **`scp` to ARM** `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` — NOT `kubectl` |
| `node-config/<node>.config.yaml` | k3s node config | **template**: `make node-config` fills `__NODE_IP__` from `NODE_IP_*` in `.env` and streams it **over ssh** to `/etc/rancher/k3s/config.yaml`, then restarts k3s — NOT `kubectl` |

The last two are the easy traps: applying them with `kubectl` does nothing useful.
Each subdirectory's README documents its own apply procedure and bootstrap order.
All four Helm releases pin their chart version in the `Makefile` (`*_CHART_VERSION`
variables) so a re-run never silently upgrades anything; `make bump APP=<name>`
shows/pins newer versions.

## Three cross-cutting conventions

**Everything is pinned to the ARM node** via `nodeSelector: kubernetes.io/arch: arm64`.
This is deliberate and load-bearing:
- The ARM node is the control-plane / server; all the other nodes are agents.
- Default storage is `local-path`, which is **node-local**. A stateful pod must stay on
  the node where its data lives, so any app with a PVC must keep the arm64 nodeSelector.
- New platform components and stateful apps should follow this pattern.

**Secrets never enter git.** Real values live in a git-ignored `.env` on the control machine
(template: `.env.example`). `scripts/apply-secrets.sh` reads `.env` and creates the
in-cluster `Secret` objects (idempotent, via `create --dry-run=client | apply`). The script
has **one block per app** (`cert-manager`, `wallos`, `multica`, `supabase`): with no args it
applies every block whose `.env` vars are filled and skips the rest; `make secrets APP=<name>`
applies just one. `make platform` depends only on the `cert-manager` block, so platform
bootstrap never requires app secrets. Manifests reference Secrets by
`secretKeyRef`/`apiTokenSecretRef` — Kubernetes does not read env vars directly.
`.gitignore` blocks `.env`, `*.secret.yaml`, `*-secret.yaml`, `*.token`, `*.key`, `*.pem`,
and kubeconfigs. Add any new secret to this flow (a new app = a new block); never inline a
real value into a manifest. **This repo is public**: node public IPs are also treated as
private — they live in `.env` (`NODE_IP_*`, rendered into the `node-config/` templates at
apply time) and SSH connection details (IP/port/user/key) live only in `~/.ssh/config`;
never commit either, in code or in docs. Supabase needs interdependent secret material (a JWT secret
plus `anon`/`service_role` keys *signed* by it), so `scripts/supabase-gen-secrets.sh` emits a
complete `.env` block once and `apply-secrets.sh` creates the eight `supabase-*` Secrets the
chart references.

**Stateful apps get a nightly backup CronJob.** `apps/<name>/backup.yaml` dumps the app's
state (`pg_dump`/`pg_dumpall` over the cluster network and/or a read-only tar of its PVCs)
and uploads to Cloudflare R2 (`backups/<name>/`, 30-day retention, staggered 03:10/03:30/03:50
Asia/Shanghai). Credentials come from the `backup-r2` Secret in the app's namespace
(`BACKUP_R2_*` in `.env` → `apply-secrets.sh`). wallos applies it via its kustomization;
multica/supabase apply it inside their make targets (it is NOT part of their Helm releases).
`make backup-now APP=<name>` runs one immediately and prints the log. A new stateful app
should ship a `backup.yaml` following the same pattern.

## Common commands

The `Makefile` is the canonical entry point — each target is a thin, self-documenting
wrapper around the raw command, so prefer `make <target>` and read the Makefile to see
exactly what it runs. `make` with no args lists everything.

```bash
make status                 # nodes + all pods
make diff                   # drift preview: repo vs live cluster (applies nothing)
make platform               # bootstrap/refresh ALL platform components in the right order
make cert-manager           # helm upgrade cert-manager (pinned chart) + apply its ClusterIssuer
make headlamp               # helm upgrade headlamp (pinned chart) + apply its admin login
make traefik                # scp the ARM-pin config to the server node
make app APP=<name>         # kubectl apply -k apps/<name>/
make bump APP=<name>        # show/pin a version (kustomize image, multica chart+images, or a Makefile chart pin)
make node-config NODE=sg    # render node config from .env + push + restart k3s
make secrets                # ./scripts/apply-secrets.sh (APP=<name> for one app's block)
make backup-now APP=<name>  # run an app's nightly R2 backup right now
make headlamp-token         # print the Headlamp admin login token
```

**Control-machine prerequisites (the easy-to-miss ones):** the control machine drives the
cluster with `kubectl` + `helm` from Homebrew (keep kubectl within ±1 minor of the cluster,
which runs v1.35). A fresh `helm` has **no repositories**, so `make repos` (adds `jetstack` +
`headlamp` + `supabase`, plus the `helm-diff` plugin that `make diff` needs) is a real
prerequisite — without it every `helm upgrade` fails to find its chart. `.env` must exist
for `make secrets`.

## Adding a new app

Copy the `templates/service-with-tls/` recipe (Namespace + Deployment + Service +
Ingress, exposed at `https://<name>.lkwplus.com` with an auto-issued Let's Encrypt cert
via the `letsencrypt-cf` ClusterIssuer and `cert-manager.io/cluster-issuer` annotation):

```bash
cp -r templates/service-with-tls apps/<name>   # folder name = namespace
# edit apps/<name>/*.yaml: rename "myapp", set host & image (pin a real tag, not :latest)
#   `make bump APP=<name>` lists the newest published tags (or pins one into deployment.yaml)
kubectl apply -k apps/<name>/
# add Cloudflare DNS: <name> CNAME arm.lkwplus.com (grey cloud / DNS-only)
```

For persistence: add a `pvc.yaml` using the `local-path` StorageClass, uncomment its line
in `kustomization.yaml` and the `volumeMounts`/`volumes` blocks in `deployment.yaml`, and
keep the arm64 nodeSelector so the pod returns to where its data lives.

## Cluster topology

`arm` = control-plane (arm64); `amd1`, `amd2`, `sg` = agents (amd64). `sg` is tainted
`location=singapore`. Networking is a Tailscale mesh; ingress is Traefik (pinned to ARM).
SSH aliases (`arm`/`amd1`/`amd2`/`sg`) are defined in `~/.ssh/config` on the control
machine; node public IPs live in `.env` as `NODE_IP_*` — neither is in the repo. The
cluster node names (`k3s-ora-arm-1`, etc.) differ from the SSH aliases.
