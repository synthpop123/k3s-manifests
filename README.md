# k3s-manifests

Version-controlled source-of-truth for the **lkwplus.com k3s cluster**: platform
components, per-node settings, and a template for new apps.

This repo is public as a working reference for a small, push-based homelab setup —
multi-arch k3s, Traefik + cert-manager TLS, Helm + kustomize apps, nightly R2 backups,
drift checking — while everything private stays out of git: credentials and node IPs
live in a git-ignored `.env`, SSH connection details live only in `~/.ssh/config`.

## Workflow — edit here, apply from your control machine

This is a **push-based** workflow: the repo lives on your control machine (and GitHub), and
you push changes *to* the cluster over the public API. The cluster never reads GitHub.

```
edit YAML locally ──▶  kubectl apply -k / helm upgrade  ──▶  k3s.lkwplus.com:6443 (ARM)
       │                  (over public API)
       └──▶ git commit && git push  ──▶  GitHub (private repo)
```

The ARM node needs **no clone and no git/`gh` auth** — nothing in the cluster pulls from
GitHub. Git/`gh` auth is only needed on your control machine to `git push`. The two
exceptions are `platform/traefik/` and `node-config/`, which are `scp`'d to a node rather
than applied with `kubectl` (see those folders' READMEs).

### One-time setup on a control machine

The control machine is where you run `kubectl`/`helm` for this repo. To make the commands
below work:

```bash
brew install kubectl helm          # kubectl within ±1 minor of the cluster (v1.35)
kubectl get nodes                  # confirm the kubeconfig points at k3s.lkwplus.com
make repos                         # helm repos (jetstack/headlamp/supabase) + helm-diff plugin (once per machine)
cp .env.example .env               # then fill in real values (see Secrets policy)
```

> A fresh `helm` has no repositories, so `make repos` (or `helm repo add ...`) is a real
> prerequisite for any `helm upgrade` below — skip it and the upgrade fails to find the chart.

## Structure

```
platform/      # cluster-wide infra, installed once (traefik, cert-manager, headlamp)
apps/          # one folder per deployed app (wallos, multica, supabase)
templates/     # copy-me starting points (service-with-tls: Namespace+Deployment+Service+Ingress)
node-config/   # /etc/rancher/k3s/config.yaml templates per node (rendered from .env, pushed over ssh)
scripts/       # apply-secrets.sh, supabase-gen-secrets.sh, bump-app-image.sh
```

Each subfolder has its own README with apply procedures and bootstrap order.

## Common tasks

Run `make` (no args) for the full list. The common ones:

```bash
make status                 # nodes + all pods at a glance
make diff                   # preview drift: repo vs live cluster (applies nothing)
make headlamp-token         # print the Headlamp admin login token
make cert-manager           # helm upgrade cert-manager (pinned chart) + apply its ClusterIssuer
make headlamp               # helm upgrade headlamp (pinned chart) + apply its admin login
make platform               # bootstrap/refresh ALL platform components, in the right order
make app APP=wallos         # kubectl apply -k apps/wallos/  (deploy/update an app)
make bump APP=wallos        # bump a pinned image tag / chart version, then re-apply
make multica                # install/upgrade multica (Helm chart) + its TLS cert + backup CronJob
make supabase               # install/upgrade Supabase (Helm chart) + backup CronJob
make node-config NODE=sg    # render sg's k3s config from .env, push it, restart k3s
make secrets                # create/rotate in-cluster Secrets from .env (APP=<name> for one app)
make backup-now APP=wallos  # run an app's nightly R2 backup right now

git add -A && git commit -m "..." && git push   # save changes
```

Each target is a thin wrapper around the underlying `kubectl`/`helm`/`scp` command — read
the [`Makefile`](Makefile) to see exactly what runs. Add a new app:
[`templates/service-with-tls/README.md`](templates/service-with-tls/README.md). Rebuild the
platform from scratch: [`platform/README.md`](platform/README.md).

## Secrets policy

**Never commit real secrets.** Real values live in a git-ignored `.env` on your control machine
(template: [`.env.example`](.env.example)); they exist as Secrets only inside the cluster.
Manifests don't read env vars — the script reads `.env` and creates the Secret objects;
pods reference them via `secretKeyRef`/`apiTokenSecretRef`. `.env` also carries the
private-but-not-secret `NODE_IP_*` values consumed directly by `make node-config`
(they never become cluster Secrets).

```bash
cp .env.example .env          # fill in the real values
make secrets                  # = ./scripts/apply-secrets.sh — create/rotate Secrets (idempotent)
```

| Secret | Namespace | Source |
|---|---|---|
| `cloudflare-api-token` | `cert-manager` | `CLOUDFLARE_API_TOKEN` in `.env` → `scripts/apply-secrets.sh` |
| `headlamp-login-token` | `headlamp` | auto-populated by Kubernetes from `platform/headlamp/headlamp-login.yaml` |
| `multica-secrets` | `multica` | `MULTICA_*` in `.env` → `scripts/apply-secrets.sh` |
| `supabase-*` (8: jwt, db, dashboard, analytics, realtime, meta, s3, smtp) | `supabase` | `SUPABASE_*` in `.env` → `scripts/apply-secrets.sh` |
| `backup-r2` | `wallos`, `multica`, `supabase` | `BACKUP_R2_*` in `.env` → `scripts/apply-secrets.sh` |

`apply-secrets.sh` has one block per app: with no args it applies every block whose
`.env` vars are filled in (and skips the rest), and `make secrets APP=<name>` applies
just one. `make platform` only needs the `cert-manager` block, so bootstrapping the
platform never depends on app secrets.

The `SUPABASE_*` values (incl. JWT-signed anon/service keys) are produced once by
[`scripts/supabase-gen-secrets.sh`](scripts/supabase-gen-secrets.sh) — see
[`apps/supabase/README.md`](apps/supabase/README.md).

`.gitignore` blocks `.env`, `*.secret.yaml`, `*.token`, `*.key`, `*.pem`, and kubeconfigs.
Leveling up later: **Sealed Secrets** or **SOPS** to store encrypted secrets in git.

## Backups

Each stateful app has a nightly CronJob (`apps/<name>/backup.yaml`) that dumps its state
and uploads it to **Cloudflare R2** (`backups/<name>/` in the `BACKUP_R2_BUCKET` bucket),
pruning copies older than 30 days:

| App | Schedule (Asia/Shanghai) | What's backed up |
|---|---|---|
| `wallos` | 03:10 | one tgz: SQLite db + uploaded logos (pod directory layout) |
| `multica` | 03:30 | `pg_dump` of the multica DB + tgz of the uploads PVC |
| `supabase` | 03:50 | `pg_dumpall` (all roles/DBs incl. `_supabase`) + tgz of the storage PVC |

Credentials are the `BACKUP_R2_*` values in `.env` → `make secrets` → a `backup-r2`
Secret in each app namespace. Run one immediately with `make backup-now APP=<name>`;
restore procedures live in each app's README.

## Cluster at a glance

| Node | SSH alias | Role | Arch |
|---|---|---|---|
| `k3s-ora-arm-1`    | `arm`  | control-plane (server) | arm64 |
| `k3s-ora-amd-1`    | `amd1` | agent | amd64 |
| `k3s-ora-amd-2`    | `amd2` | agent | amd64 |
| `k3s-tencent-sg-1` | `sg`   | agent (tainted `location=singapore`) | amd64 |

- Networking: Tailscale mesh. Ingress: Traefik (pinned to ARM). Everything is pinned to
  the ARM node via `nodeSelector: kubernetes.io/arch: arm64`.
- Storage: default `local-path` (node-local → keep stateful apps on ARM).
- Node public IPs are deliberately not in the repo: they live in `.env` as `NODE_IP_*`
  (see [`node-config/`](node-config)).

## SSH access

Every make target that touches a node (`make traefik`, `make node-config`, `make diff`)
connects through the SSH aliases `arm` / `amd1` / `amd2` / `sg`. The aliases — and every
connection detail behind them (IP, port, user, key) — live only in `~/.ssh/config` on
the control machine, never in this repo:

```sshconfig
Host arm
    HostName <arm public IP>      # same value as NODE_IP_ARM in .env
    Port <ssh port>
    User <user>
    IdentityFile ~/.ssh/<key>
# repeat for amd1 / amd2 / sg
```

## License

[MIT](LICENSE)
