# k3s-manifests

[![lint](https://github.com/synthpop123/k3s-manifests/actions/workflows/ci.yml/badge.svg)](https://github.com/synthpop123/k3s-manifests/actions/workflows/ci.yml)

Version-controlled source-of-truth for the **lkwplus.com k3s cluster**: platform
components, per-node settings, and a template for new apps.

This repo is public as a working reference for a small, push-based homelab setup —
multi-arch k3s, Traefik + cert-manager TLS, Helm + kustomize apps, nightly R2 backups,
drift checking, CI validation — while everything private is either encrypted or absent:
credentials and node IPs live in [`secrets.enc.env`](secrets.enc.env), encrypted with
SOPS + age (only ciphertext is committed); SSH connection details live only in
`~/.ssh/config`.

## What runs here

The cluster is small on purpose: k3s provides the core Kubernetes services, Traefik handles
public ingress, cert-manager issues TLS certificates, and this repo keeps the deployed apps
and their pinned versions visible in git.

### Platform

| Component | Namespace / path | What it does | Managed by |
|---|---|---|---|
| k3s core add-ons | `kube-system` | CoreDNS, metrics-server, `local-path` storage, and the packaged Traefik release | k3s |
| Traefik | `platform/traefik/` | Public HTTP/HTTPS ingress for `*.lkwplus.com`, pinned to the ARM server node | k3s `HelmChartConfig` copied by `make traefik` |
| cert-manager | `cert-manager` | Let's Encrypt certificates through the Cloudflare DNS-01 ClusterIssuer | Helm + plain manifest via `make cert-manager` |
| Headlamp | `headlamp` | Kubernetes web dashboard with an admin login token | Helm + plain manifest via `make headlamp` |
| SOPS-backed Secret sync | `scripts/apply-secrets.sh` | Decrypts `secrets.enc.env` locally and creates the Kubernetes Secrets each app references | `make secrets` |
| Nightly backups | `apps/*/backup.yaml` | Uploads stateful app backups to Cloudflare R2 and prunes old copies | Kubernetes CronJobs |

### Deployed apps

| App | Public entrypoint | Runtime shape | State and backup |
|---|---|---|---|
| [`wallos`](apps/wallos) | https://wallos.lkwplus.com | Kustomize app: PHP/Apache + SQLite, image pinned in `deployment.yaml` | Two `local-path` PVCs, nightly R2 backup at 03:10 |
| [`multica`](apps/multica) | https://multica.lkwplus.com, API at https://api.multica.lkwplus.com | Helm app: Go backend, Next.js frontend, PostgreSQL/pgvector, chart and images pinned together | Postgres PVC + uploads PVC, nightly R2 backup at 03:30 |
| [`supabase`](apps/supabase) | https://supabase.lkwplus.com | Helm app: Supabase stack behind Kong, including Auth, REST, Realtime, Storage, Functions, Studio, and Postgres | Database + storage PVCs, nightly R2 backup at 03:50 |

All public apps use Traefik ingress and cert-manager TLS. Stateful workloads stay on the ARM
node because the default `local-path` storage is node-local. The `apps/` directories should
match what is actually deployed: add a folder when a service goes live, remove it when the
service is uninstalled.

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
brew install kubernetes-cli helm kubeconform shellcheck sops age
kubectl version --client # kubernetes-cli provides kubectl; keep it within ±1 minor of the cluster (v1.36)
kubectl get nodes        # confirm the kubeconfig points at k3s.lkwplus.com
make repos               # helm repos (jetstack/headlamp/supabase) + helm-diff plugin (once per machine)
# restore the age private key from your password manager to:
#   '~/Library/Application Support/sops/age/keys.txt'   (macOS; Linux: ~/.config/sops/age/keys.txt)
```

> A fresh `helm` has no repositories, so `make repos` (or `helm repo add ...`) is a real
> prerequisite for any `helm upgrade` below — skip it and the upgrade fails to find the chart.
> `make repos` also installs the `helm-diff` plugin needed by `make diff`; the equivalent raw
> command is `helm plugin install --verify=false https://github.com/databus23/helm-diff`.

### CI — validation without touching the cluster

Every push runs [`make lint`](Makefile) in GitHub Actions
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)): kustomize builds and the four
pinned Helm releases are rendered and schema-checked with `kubeconform -strict` against
the cluster's Kubernetes version (so a YAML typo or a values/chart mismatch fails in CI
instead of at apply time), `shellcheck` covers `scripts/`, and a hygiene check proves
`secrets.enc.env` contains only encrypted values. CI is validation-only by design: the
cluster can't be reached from GitHub — no kubeconfig, SSH key or age key exists there.

## Structure

```
platform/        # cluster-wide infra, installed once (traefik, cert-manager, headlamp)
apps/            # one folder per deployed app (wallos, multica, supabase)
templates/       # copy-me starting points (service-with-tls: Namespace+Deployment+Service+Ingress)
node-config/     # /etc/rancher/k3s/config.yaml templates per node (IPs decrypted from secrets.enc.env, pushed over ssh)
scripts/         # apply-secrets.sh, supabase-gen-secrets.sh, bump-app-image.sh
secrets.enc.env  # ALL secrets + node IPs, sops+age-encrypted (committed; see Secrets policy)
```

Each subfolder has its own README with apply procedures and bootstrap order.

## Common tasks

Run `make` (no args) for the full list. The common ones:

```bash
make status                 # nodes + all pods at a glance
make diff                   # preview drift: repo vs live cluster (applies nothing)
make lint                   # validate everything CI validates (manifests, charts, scripts, secrets hygiene)
make headlamp-token         # print the Headlamp admin login token
make cert-manager           # helm upgrade cert-manager (pinned chart) + apply its ClusterIssuer
make headlamp               # helm upgrade headlamp (pinned chart) + apply its admin login
make platform               # bootstrap/refresh ALL platform components, in the right order
make app APP=wallos         # kubectl apply -k apps/wallos/  (deploy/update an app)
make bump APP=wallos        # bump a pinned image tag / chart version, then re-apply
make multica                # install/upgrade multica (Helm chart) + its TLS cert + backup CronJob
make supabase               # install/upgrade Supabase (Helm chart) + backup CronJob
make node-config NODE=sg    # render sg's k3s config (IP decrypted via sops), push it, restart k3s
make secrets-edit           # edit the encrypted secrets file (sops decrypts into your editor)
make secrets                # create/rotate in-cluster Secrets from secrets.enc.env (APP=<name> for one app)
make backup-now APP=wallos  # run an app's nightly R2 backup right now

git add -A && git commit -m "..." && git push   # save changes (CI lints every push)
```

Each target is a thin wrapper around the underlying `kubectl`/`helm`/`scp` command — read
the [`Makefile`](Makefile) to see exactly what runs. Add a new app:
[`templates/service-with-tls/README.md`](templates/service-with-tls/README.md). Rebuild the
platform from scratch: [`platform/README.md`](platform/README.md).

## Secrets policy

**Never commit plaintext secrets.** Every credential — plus the private-but-not-secret
`NODE_IP_*` values — lives in [`secrets.enc.env`](secrets.enc.env), a dotenv encrypted
with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
that **is committed**: variable names and comments stay readable, every value is an
`ENC[...]` blob (CI fails the build if a plaintext value ever sneaks in). The age
recipient is pinned in [`.sops.yaml`](.sops.yaml); the matching **private key** exists
only on the control machine — macOS `~/Library/Application Support/sops/age/keys.txt`
(Linux `~/.config/sops/age/keys.txt`) — **and as a backup in your password manager**.
Disaster recovery is exactly: this repo + that one key.

> Why SOPS over Sealed Secrets: SOPS is pure client-side, which fits the push model —
> no controller to run in the cluster, and a dead cluster can't take the decryption
> key down with it.

```bash
make secrets-edit             # sops decrypts into your editor, re-encrypts on save
make secrets                  # = ./scripts/apply-secrets.sh — sops -d in-memory → create/rotate Secrets (idempotent)
```

Manifests don't read env vars — `apply-secrets.sh` decrypts in-memory (plaintext never
touches disk) and creates the Secret objects; pods reference them via
`secretKeyRef`/`apiTokenSecretRef`. `NODE_IP_*` is consumed directly by
`make node-config` and never becomes a cluster Secret.

| Secret | Namespace | Source |
|---|---|---|
| `cloudflare-api-token` | `cert-manager` | `CLOUDFLARE_API_TOKEN` in `secrets.enc.env` → `scripts/apply-secrets.sh` |
| `headlamp-login-token` | `headlamp` | auto-populated by Kubernetes from `platform/headlamp/headlamp-login.yaml` |
| `multica-secrets` | `multica` | `MULTICA_*` in `secrets.enc.env` → `scripts/apply-secrets.sh` |
| `supabase-*` (8: jwt, db, dashboard, analytics, realtime, meta, s3, smtp) | `supabase` | `SUPABASE_*` in `secrets.enc.env` → `scripts/apply-secrets.sh` |
| `backup-r2` | `wallos`, `multica`, `supabase` | `BACKUP_R2_*` in `secrets.enc.env` → `scripts/apply-secrets.sh` |

`apply-secrets.sh` has one block per app: with no args it applies every block whose
vars are filled in (and skips the rest), and `make secrets APP=<name>` applies just
one. `make platform` only needs the `cert-manager` block, so bootstrapping the
platform never depends on app secrets.

The `SUPABASE_*` values (incl. JWT-signed anon/service keys) are produced once by
[`scripts/supabase-gen-secrets.sh`](scripts/supabase-gen-secrets.sh) — paste its output
into the editor opened by `make secrets-edit` — see
[`apps/supabase/README.md`](apps/supabase/README.md).

Bootstrapping:

- **Existing cluster, new machine:** install the control-machine tools from the setup
  section above, restore the age key from your password manager to the path above,
  `git clone` — done.
- **From zero (or lost key):** `age-keygen -o <key path above>`, put the printed
  recipient in [`.sops.yaml`](.sops.yaml), then `make secrets-edit` and fill in the
  variables listed in [`.env.example`](.env.example). Back the new key up immediately.

`.gitignore` still blocks plaintext leftovers (`.env`, `*.secret.yaml`, `*.token`,
`*.key`, `*.pem`, kubeconfigs), and `make lint` / CI verify `secrets.enc.env` stays
fully encrypted.

## Backups

Each stateful app has a nightly CronJob (`apps/<name>/backup.yaml`) that dumps its state
and uploads it to **Cloudflare R2** (`backups/<name>/` in the `BACKUP_R2_BUCKET` bucket),
pruning copies older than 30 days:

| App | Schedule (Asia/Shanghai) | What's backed up |
|---|---|---|
| `wallos` | 03:10 | one tgz: SQLite db + uploaded logos (pod directory layout) |
| `multica` | 03:30 | `pg_dump` of the multica DB + tgz of the uploads PVC |
| `supabase` | 03:50 | `pg_dumpall` (all roles/DBs incl. `_supabase`) + tgz of the storage PVC |

Credentials are the `BACKUP_R2_*` values in `secrets.enc.env` → `make secrets` → a
`backup-r2` Secret in each app namespace. Run one immediately with `make backup-now APP=<name>`;
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
- Node public IPs are deliberately never committed in plaintext: they live encrypted in
  `secrets.enc.env` as `NODE_IP_*` (see [`node-config/`](node-config)).

## SSH access

Every make target that touches a node (`make traefik`, `make node-config`, `make diff`)
connects through the SSH aliases `arm` / `amd1` / `amd2` / `sg`. The aliases — and every
connection detail behind them (IP, port, user, key) — live only in `~/.ssh/config` on
the control machine, never in this repo:

```sshconfig
Host arm
    HostName <arm public IP>      # same value as NODE_IP_ARM in secrets.enc.env
    Port <ssh port>
    User <user>
    IdentityFile ~/.ssh/<key>
# repeat for amd1 / amd2 / sg
```

## License

[MIT](LICENSE)
