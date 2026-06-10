# multica

[Multica](https://multica.ai) — an AI-native issue tracker (like Linear, with AI agents as
first-class citizens). Self-hosted, it's three components: a Go backend (REST + WebSocket), a
Next.js frontend, and PostgreSQL (pgvector). Web UI at **https://multica.lkwplus.com**, backend
API at **https://api.multica.lkwplus.com**.

Deployed from the upstream **Helm chart** (`oci://ghcr.io/multica-ai/charts/multica`), not the
kustomize recipe the other apps use — so it's driven by [`values.yaml`](./values.yaml) + a
`make multica` target instead of `make app`.

## Why it's shaped this way

- **Helm, not kustomize.** Multica ships an official chart tuned for k3s + Traefik +
  `local-path`. Re-deriving it as hand-written manifests would be fragile, so we consume the
  chart and override only what differs in [`values.yaml`](./values.yaml). The chart version is
  pinned as `MULTICA_CHART_VERSION` in the root [`Makefile`](../../Makefile).
- **Two hostnames are mandatory.** The prebuilt web image bakes `REMOTE_API_URL=http://backend:8080`
  at build time and proxies `/api`, `/ws`, `/auth`, `/uploads` to an in-cluster `backend`
  ExternalName alias — but the **CLI/daemon** and **uploaded-file URLs** (`localUploadBaseUrl`)
  hit the backend host directly. So `multica.lkwplus.com` (web) **and** `api.multica.lkwplus.com`
  (backend) both need DNS. Only one release per namespace (the alias Service is literally `backend`).
- **Images pinned** to `v0.3.17` in [`values.yaml`](./values.yaml) — never the chart's mutable
  `appVersion: latest`. Postgres is `pgvector/pgvector:pg17`.
- **Scheduler-placed (no arm64 pin).** The chart exposes no `nodeSelector`, so placement is left
  to the scheduler. In practice all three pods land on the **ARM** node — it's the only one with
  real headroom (~24Gi RAM vs ~1Gi on the amd agents), so multica, the heaviest workload here,
  won't fit elsewhere. Data stays put either way: the `local-path` PVs (10Gi Postgres, 5Gi
  uploads) get node affinity to wherever they first bind, so the stateful pods return there.
- **Secrets via `secrets.enc.env`.** `multica-secrets` (JWT, Postgres password, Resend key, GitHub
  App creds, + empty optionals) is created by
  [`../../scripts/apply-secrets.sh`](../../scripts/apply-secrets.sh) from the sops-encrypted
  `secrets.enc.env` (edit with `make secrets-edit`);
  the chart references it by name. The vars are project-prefixed (`MULTICA_JWT_SECRET`,
  `MULTICA_RESEND_API_KEY`, `MULTICA_GITHUB_*`) and the script maps them to the un-prefixed keys
  the backend actually reads (`JWT_SECRET`, `RESEND_API_KEY`, `GITHUB_*`). The chart has no
  extra-env knob, so even the non-secret GitHub `SLUG`/`APP_ID` ride in this Secret — it's the
  only `envFrom` hook. The Resend *From* address is non-secret and lives in `values.yaml`.
- **TLS via an explicit Certificate** ([`certificate.yaml`](./certificate.yaml)) covering both
  SANs, because the chart applies one `tls` block to both ingresses.

## DNS

Two Cloudflare records, both grey-cloud (DNS-only), pointing at the ARM node:

```
multica      CNAME  arm.lkwplus.com
api.multica  CNAME  arm.lkwplus.com
```

The Let's Encrypt cert is issued via Cloudflare DNS-01, so it succeeds even before these resolve
— but the backend host is only *reachable* once `api.multica` exists.

## Deploy

```bash
make secrets                 # create multica-secrets from secrets.enc.env (JWT/Postgres/Resend/GitHub) — run first
make multica                 # apply cert + backup CronJob, then helm upgrade --install (waits up to 10m)
```

On a cold start the backend can sit `Running` but not `Ready` for a few minutes while Postgres
comes up and migrations run (a startupProbe absorbs this). Confirm:

```bash
kubectl -n multica get pods
kubectl -n multica get certificate          # multica-tls READY=True
curl -sS -o /dev/null -w "%{http_code}\n" https://multica.lkwplus.com/        # 200
```

## First login

`APP_ENV=production`, so there's no fixed code. With Resend configured (it is), open
https://multica.lkwplus.com, enter your email, and use the emailed code. (Resend requires the
`lkwplus.com` sender domain to be verified.) No email? Read the code from the logs:

```bash
kubectl -n multica logs deploy/multica-backend | grep "Verification code"
```

Then create the first workspace. Public signup is now closed —
`backend.config.allowSignup: false` in [`values.yaml`](./values.yaml) (the web reads it from
`/api/config`); flip it back to `true` and `make multica` to reopen registration.

## GitHub integration

PRs whose branch/title/body mention an issue id (`MUL-123`) auto-link to that issue, and merging
the PR flips the issue to Done. Setup is a one-time GitHub App + four env vars, all carried in
`multica-secrets` via `secrets.enc.env` → `apply-secrets.sh`:

| `secrets.enc.env` var | Secret key (backend reads) | Required |
|---|---|---|
| `MULTICA_GITHUB_APP_SLUG` | `GITHUB_APP_SLUG` | yes |
| `MULTICA_GITHUB_WEBHOOK_SECRET` | `GITHUB_WEBHOOK_SECRET` | yes |
| `MULTICA_GITHUB_APP_ID` | `GITHUB_APP_ID` | optional (nicer "connected to &lt;org&gt;") |
| `MULTICA_GITHUB_APP_PRIVATE_KEY_B64` | `GITHUB_APP_PRIVATE_KEY` | optional |

The private key is a multiline PEM, so it's stored base64 on one `secrets.enc.env` line
(`openssl base64 -A < app.private-key.pem`) and decoded back to the raw PEM by `apply-secrets.sh`.

On the **GitHub App** itself, the two URLs must point here:

```
Webhook URL  https://api.multica.lkwplus.com/api/webhooks/github
Setup URL    https://multica.lkwplus.com/api/github/setup   (tick "Redirect on update")
```

Permissions: Repository → Pull requests + Metadata, both **Read-only**; subscribe to **Pull
request** events; Webhook **Active** with the secret above. Then **Settings → GitHub → Connect**
in the Multica UI and install the App on the repos you want. Migrations (`079_github_integration`)
already ran with the v0.3.17 deploy.

Verify the backend loaded the secret correctly (expect `200 {"ok":"pong"}`):

```bash
SECRET="$(sops -d secrets.enc.env | sed -n 's/^MULTICA_GITHUB_WEBHOOK_SECRET=//p')"
SIG=$(printf '%s' '{"zen":"test"}' | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $NF}')
curl -i -X POST https://api.multica.lkwplus.com/api/webhooks/github \
  -H "X-Hub-Signature-256: sha256=$SIG" -H "X-GitHub-Event: ping" \
  -H "Content-Type: application/json" -d '{"zen":"test"}'
```

`401 invalid signature` in GitHub's *Recent Deliveries* (while this returns `200`) means the App's
Webhook-secret field doesn't match `secrets.enc.env` — re-paste and **Save** on GitHub. `503 not configured`
means the backend has no `GITHUB_WEBHOOK_SECRET` (re-run `make secrets && make multica`).

## Upgrade

```bash
make bump APP=multica                  # list newest chart versions published on ghcr.io
make bump APP=multica VERSION=0.3.18   # pin chart (Makefile) + both image tags (values.yaml) in lockstep
make multica                           # apply
kubectl -n multica rollout status deploy/multica-backend
```

`make bump` edits files only (a reviewable `git diff`) — nothing reaches the cluster until
`make multica`. It validates the requested version against ghcr.io (chart `X.Y.Z` + image `vX.Y.Z`)
before rewriting, so a typo'd tag fails fast instead of producing an ImagePullBackOff.

Migrations run automatically on backend startup (the entrypoint runs `migrate up`, serialized by
a Postgres advisory lock). Roll back with `helm -n multica rollback multica`.

## Backup & restore

State = the Postgres database (+ the uploads volume). [`backup.yaml`](./backup.yaml) backs
both up **automatically every night** (03:30 Asia/Shanghai): an init container `pg_dump`s
the database over the cluster network, the main container tars the uploads PVC (read-only
mount) and uploads both to R2 at `backups/multica/` with 30-day retention. It's applied by
`make multica` (alongside certificate.yaml — it is NOT part of the Helm release). R2
credentials come from the `backup-r2` Secret (`BACKUP_R2_*` in `secrets.enc.env` → `make secrets`).

```bash
make backup-now APP=multica     # run a backup right now + print the log (lists the bucket)
```

Restore (fetch the files from R2 first — Cloudflare dashboard, or `rclone` with the same
credentials):

```bash
# Database
gunzip -c multica-db-YYYY-MM-DD.sql.gz \
  | kubectl -n multica exec -i deploy/multica-postgres -- sh -c 'psql -U multica multica'

# Uploads (archive contains uploads/; the backend mounts the PVC at /app/data/uploads)
kubectl -n multica exec -i deploy/multica-backend -- tar xzf - -C /app/data \
  < multica-uploads-YYYY-MM-DD.tgz
```

## Uninstall

```bash
helm -n multica uninstall multica     # removes workloads; keeps PVCs + multica-secrets
kubectl delete namespace multica      # wipes EVERYTHING (Postgres data + uploads) permanently
```

Then drop the `multica` / `api.multica` CNAMEs, remove the multica block from `secrets.enc.env`
(`make secrets-edit`) / `.env.example` / `apply-secrets.sh`, and delete this folder + its row in
[`../README.md`](../README.md).

## Troubleshooting

```bash
make status                                          # pods across nodes
kubectl -n multica describe pod -l app.kubernetes.io/component=backend
kubectl -n multica logs deploy/multica-backend       # migrations, email provider, errors
kubectl -n multica get certificate,ingress
```

- **Backend `Running` but not `Ready` for minutes** → normal on first boot (migrations); the
  startupProbe gives ~5 min. Watch the logs.
- **WebSocket won't connect** → `frontendOrigin` must equal the real web URL (it does in
  `values.yaml`); a mismatch makes the backend reject the browser's WS origin.
- **Uploaded images 404 / CLI can't connect** → the `api.multica` CNAME isn't resolving yet.
- **Email codes not arriving** → verify `lkwplus.com` in Resend; otherwise read the code from
  the backend logs.
