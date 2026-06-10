# supabase

[Supabase](https://supabase.com) self-hosted — the full open-source backend platform (Postgres
+ Auth + REST + Realtime + Storage + Edge Functions + Studio). One public entrypoint at
**https://supabase.lkwplus.com**.

Deployed from the community **Helm chart**
([`supabase-community/supabase-kubernetes`](https://github.com/supabase-community/supabase-kubernetes)),
not the kustomize recipe the simple apps use — so it's driven by [`values.yaml`](./values.yaml) +
a `make supabase` target instead of `make app`.

## Architecture

Twelve components run together; **Kong** (the API gateway) is the *only* thing the Ingress
exposes. Everything else is reached through Kong by path, so there's a single hostname and a
single TLS cert:

| Path (under `https://supabase.lkwplus.com`) | Routes to | Auth |
|---|---|---|
| `/` | Studio dashboard | Kong **basic-auth** (dashboard user/pass) |
| `/rest/v1/*`, `/graphql/v1` | PostgREST | `apikey` header (anon / service key) |
| `/auth/v1/*` | GoTrue | `apikey` header |
| `/realtime/v1/*` | Realtime (WebSocket) | `apikey` header |
| `/storage/v1/*` | Storage API | `apikey` header |
| `/functions/v1/*` | Edge Functions (Deno) | per-function |
| `/pg/*` | postgres-meta | service key |

Postgres itself has **no Ingress** — it's internal-only (`ClusterIP`). Reach it from the Studio
SQL editor or via `kubectl port-forward` (see [Connect to Postgres](#connect-to-postgres)).

## Why it's shaped this way

- **Helm, not kustomize.** Twelve interdependent services (init-container ordering, a Kong
  declarative config rendered from secrets, an initdb pipeline) would be miserable as
  hand-written manifests. We consume the chart and override only what differs in
  [`values.yaml`](./values.yaml). The chart version is pinned as `SUPABASE_CHART_VERSION` in the
  root [`Makefile`](../../Makefile).
- **One number controls everything.** The chart pins every component image tag internally
  (Postgres `15.8.1.085`, Studio, Kong `3.9.1`, GoTrue, …), so an upgrade is just a chart bump —
  no per-image tags in our `values.yaml` (contrast multica). Bump with `make bump APP=supabase`.
- **Pinned to ARM** (`nodeSelector: kubernetes.io/arch: arm64` on all 12 components). ARM is the
  only large node (4 CPU / 24Gi vs ~1Gi on the amd/sg agents), and the DB + storage use
  node-local `local-path` PVCs, so the stateful pods must live where their data binds. See the
  root [`AGENTS.md`](../../AGENTS.md).
- **Secrets out-of-git, one per concern.** Eight `supabase-*` Secrets (jwt, db, dashboard,
  analytics, realtime, meta, s3, smtp) are created by
  [`../../scripts/apply-secrets.sh`](../../scripts/apply-secrets.sh) from the git-ignored `.env`
  and referenced by name (`secret.<group>.secretRef`). Each uses the chart's natural key names,
  so no key remapping. The `apikey` secret is intentionally left empty — that keeps the classic
  **symmetric-JWT** auth model (anon / service keys); the chart's kong-entrypoint strips the
  empty credentials at boot.
- **`anon` / `service_role` keys are JWTs signed by the JWT secret**, so they can't be random —
  [`../../scripts/supabase-gen-secrets.sh`](../../scripts/supabase-gen-secrets.sh) signs them
  (10-year expiry) and rolls every other token, emitting a ready-to-paste `.env` block.
- **File storage backend** (MinIO disabled): uploads land on the `supabase-storage` PVC. The
  trade-off is image-transformation has no shared object store; flip on `minio.enabled` + the S3
  env if you need it later.
- **Locked down by default.** Public signup is **off** (`GOTRUE_DISABLE_SIGNUP: true`) — create
  users from Studio or with the service key. Auth emails go through **Resend** SMTP
  (`smtp.resend.com:465`, sender `supabase@lkwplus.com`).

## DNS

One Cloudflare record, grey-cloud (DNS-only), pointing at the ARM node:

```
supabase   CNAME   arm.lkwplus.com
```

The Let's Encrypt cert is issued via Cloudflare DNS-01, so it succeeds even before this resolves.

## Deploy

```bash
./scripts/supabase-gen-secrets.sh >> .env   # ONCE: append the SUPABASE_* block, then set
                                            # SUPABASE_SMTP_PASSWORD to your Resend API key
make repos                                  # adds the supabase helm repo (once per machine)
make secrets                                # create the 8 supabase-* Secrets from .env
make supabase                               # backup CronJob + helm upgrade --install with values.yaml
```

`make supabase` returns once the resources are applied (no `--wait` — the stack has long init
chains). Watch it come up; a cold start is ~1–2 min (Postgres initdb, then dependents):

```bash
kubectl -n supabase get pods -w               # all 12 -> Running
kubectl -n supabase get certificate           # supabase-tls READY=True
curl -sS -o /dev/null -w "%{http_code}\n" https://supabase.lkwplus.com/   # 401 (basic-auth)
```

## First login

Open https://supabase.lkwplus.com — the browser prompts for the **dashboard** basic-auth
credentials (this is Kong, not Supabase auth). They're in `.env`:

```bash
grep -E '^SUPABASE_DASHBOARD_(USERNAME|PASSWORD)=' .env
# or read them back from the cluster:
kubectl -n supabase get secret supabase-dashboard \
  -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n supabase get secret supabase-dashboard \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Client API keys

Apps connect with the project URL + an API key (sent as the `apikey` header and/or
`Authorization: Bearer`):

- **Project URL:** `https://supabase.lkwplus.com`
- **anon key** (browser/public, RLS-enforced) and **service_role key** (server-side, bypasses
  RLS — keep secret) live in `.env` as `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_KEY`, or:

```bash
kubectl -n supabase get secret supabase-jwt -o jsonpath='{.data.anonKey}'    | base64 -d; echo
kubectl -n supabase get secret supabase-jwt -o jsonpath='{.data.serviceKey}' | base64 -d; echo
```

## Connect to Postgres

No public DB ingress by design. Port-forward and connect as `postgres` (password =
`SUPABASE_DB_PASSWORD`, database `postgres`):

```bash
kubectl -n supabase port-forward svc/supabase-supabase-db 5432:5432
PGPASSWORD="$(sed -n 's/^SUPABASE_DB_PASSWORD=//p' .env)" \
  psql -h 127.0.0.1 -U postgres postgres
```

## Upgrade

```bash
make bump APP=supabase                  # list current + newest published chart versions
make bump APP=supabase VERSION=0.5.7    # pin SUPABASE_CHART_VERSION in the Makefile (no apply)
git diff Makefile                       # review the one-line change
make supabase                           # apply; chart bumps all component images in lockstep
kubectl -n supabase rollout status statefulset/supabase-supabase-db
```

`make bump` edits the Makefile only — nothing reaches the cluster until `make supabase`. Roll
back with `helm -n supabase rollback supabase`. **Back up the DB before a major Postgres jump.**

## Backup & restore

State = the Postgres database (auth/storage/public schemas + the `_supabase` analytics DB)
and the storage uploads volume. [`backup.yaml`](./backup.yaml) backs both up
**automatically every night** (03:50 Asia/Shanghai): an init container `pg_dumpall`s the
whole cluster (all roles + databases) over the cluster network, the main container tars
the storage PVC (read-only mount) and uploads both to R2 at `backups/supabase/` with
30-day retention. It's applied by `make supabase` (it is NOT part of the Helm release).
R2 credentials come from the `backup-r2` Secret (`BACKUP_R2_*` in `.env` → `make secrets`).

```bash
make backup-now APP=supabase    # run a backup right now + print the log (lists the bucket)
```

Restore (fetch the files from R2 first — Cloudflare dashboard, or `rclone` with the same
credentials):

```bash
# Database (full cluster dump: roles + postgres + _supabase)
gunzip -c supabase-db-YYYY-MM-DD.sql.gz \
  | kubectl -n supabase exec -i supabase-supabase-db-0 -- sh -c 'psql -U postgres'

# Storage uploads (archive contains storage/; the storage API serves /var/lib/storage)
kubectl -n supabase exec -i deploy/supabase-supabase-storage -- tar xzf - -C /var/lib \
  < supabase-storage-YYYY-MM-DD.tgz
```

## Common toggles

All in [`values.yaml`](./values.yaml) → re-run `make supabase` to apply:

- **Reopen signup:** `environment.auth.GOTRUE_DISABLE_SIGNUP: "false"`.
- **Studio AI SQL assistant:** set `SUPABASE_OPENAI_API_KEY` in `.env` + `make secrets`.
- **Rotate the dashboard password:** edit `SUPABASE_DASHBOARD_PASSWORD` in `.env`, `make secrets`,
  then `kubectl -n supabase rollout restart deploy/supabase-supabase-kong`.

## Uninstall

```bash
helm -n supabase uninstall supabase   # removes workloads + chart PVCs (DELETES Postgres data!)
kubectl delete namespace supabase     # also wipes the supabase-* Secrets
```

The chart's PVCs are Helm-managed, so `helm uninstall` **deletes the database and uploads** —
back up first. The `supabase-*` Secrets are created out-of-band (not Helm-managed) and survive an
uninstall; deleting the namespace removes them. Then drop the `supabase` CNAME, remove the
`SUPABASE_*` block from `.env` / `.env.example` / `apply-secrets.sh`, and delete this folder + its
row in [`../README.md`](../README.md).

## Troubleshooting

```bash
make status                                                  # pods across nodes
kubectl -n supabase get pods                                 # all 12 should be 1/1
kubectl -n supabase logs deploy/supabase-supabase-auth       # GoTrue: SMTP / DB errors
kubectl -n supabase logs statefulset/supabase-supabase-db    # Postgres init + migrations
kubectl -n supabase get certificate,ingress
```

- **`401` at the root** → that's expected: Kong basic-auth on the dashboard. Use the
  `supabase-dashboard` credentials.
- **`anon`/`service` key rejected (`401`/`anon role` errors)** → the keys must be signed by the
  *current* `SUPABASE_JWT_SECRET`. If you rotated the secret, re-run `supabase-gen-secrets.sh`,
  `make secrets`, then `kubectl -n supabase rollout restart deploy --all`.
- **Auth emails not arriving** → verify the `lkwplus.com` sender domain in Resend; confirm
  `SUPABASE_SMTP_PASSWORD` is a valid Resend API key (`make secrets` after editing). Resend SMTP
  is `smtp.resend.com:465`; if 465 misbehaves, try port `587` in `values.yaml`.
- **A dependent pod stuck `Init`** → it's waiting on Postgres (`init-db` runs `pg_isready`).
  Check the db pod is `1/1` and its logs.
