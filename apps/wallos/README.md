# wallos

[Wallos](https://github.com/ellite/Wallos) — a self-hosted subscription tracker (PHP +
Apache + SQLite). Exposed at **https://wallos.lkwplus.com**.

Adapted from the upstream `docker-compose.yml` into the cluster's standard
stateful-service recipe (Namespace + PVCs + Deployment + Service + Ingress).

## Why it's shaped this way

- **Two PVCs, not one.** Upstream persists two bind mounts in unrelated paths: the SQLite
  database (`/var/www/html/db`) and uploaded logos
  (`/var/www/html/images/uploads/logos`). They map to `wallos-db` and `wallos-logos`.
- **Pinned to ARM** (`nodeSelector: kubernetes.io/arch: arm64`). `local-path` storage is
  node-local, so the pod must always return to the node where its data lives. See the
  root [`CLAUDE.md`](../../CLAUDE.md).
- **`strategy: Recreate`.** Each PVC is `ReadWriteOnce`; on upgrade the old pod must be
  torn down before the new one starts, or the new pod can't attach the volume.
- **Image pinned to an explicit version** (`bellamy/wallos:4.9.5`), never `:latest`. The
  manifest is the source of truth: you can see exactly what's running, and a rollback is a
  one-line `git revert`. Bump it with the helper script (see *Upgrade* below).
- **`TZ=Asia/Shanghai`** is the only env var, matching upstream.

## Deploy

```bash
make app APP=wallos                          # = kubectl apply -k apps/wallos/
kubectl -n wallos rollout status deploy/wallos
```

DNS is already in place: `wallos` CNAME → `arm.lkwplus.com` (grey cloud / DNS-only).
First deploy auto-issues the Let's Encrypt cert; confirm with:

```bash
kubectl -n wallos get certificate     # READY=True
curl -sS -o /dev/null -w "%{http_code}\n" https://wallos.lkwplus.com/   # 302 -> /login.php
```

On first run, open the site and register the first user — Wallos creates the admin
account through the web UI.

## Upgrade

Pinned versions, so upgrading = bump the tag in `deployment.yaml`, review the diff, apply.
The helper script reads the image repo out of the manifest and edits the tag for you:

```bash
make bump APP=wallos                  # list current + newest published versions
make bump APP=wallos VERSION=4.9.6    # rewrite deployment.yaml's tag to 4.9.6 (no apply)

git diff apps/wallos/deployment.yaml  # review the one-line change
make app APP=wallos                   # apply it; Recreate => brief downtime
kubectl -n wallos rollout status deploy/wallos
```

Data lives on the PVCs, not the pod, so it survives. **Back up the DB first** (below)
before a major version jump. To roll back, `git revert` the bump (or
`make bump APP=wallos VERSION=<old>`) and `make app APP=wallos` again.

## Backup & restore

The whole state is the SQLite DB plus the logos dir. [`backup.yaml`](./backup.yaml) backs
both up **automatically every night** (03:10 Asia/Shanghai): a CronJob mounts the two PVCs
read-only, tars them in the pod's own layout (`db/`, `images/uploads/logos/`), uploads to
R2 at `backups/wallos/wallos-<date>.tgz`, and prunes copies older than 30 days. R2
credentials come from the `backup-r2` Secret (`BACKUP_R2_*` in `secrets.enc.env` → `make secrets`).

```bash
make backup-now APP=wallos      # run a backup right now + print the log (lists the bucket)
```

Restore: fetch the tgz from R2 (Cloudflare dashboard, or `rclone` with the same
credentials), then stream it back into the pod — the archive matches `/var/www/html`:

```bash
POD=$(kubectl -n wallos get pod -l app=wallos -o jsonpath='{.items[0].metadata.name}')
kubectl -n wallos exec -i "$POD" -- tar xzf - -C /var/www/html < wallos-YYYY-MM-DD.tgz
kubectl -n wallos rollout restart deploy/wallos
```

## Uninstall

```bash
kubectl delete -k apps/wallos/        # or: kubectl delete namespace wallos
```

> Deleting the namespace **also deletes the PVCs and their data permanently.** Back up
> first if you might want it back.

Then drop the `wallos` CNAME in Cloudflare, and delete this `apps/wallos/` folder (and its
row in [`../README.md`](../README.md)) so the repo keeps mirroring live cluster state.

## Troubleshooting

```bash
make status                                   # is the pod Running on the ARM node?
kubectl -n wallos describe pod -l app=wallos  # events: image pull, volume mount, scheduling
kubectl -n wallos logs -l app=wallos          # Apache / PHP errors
kubectl -n wallos get certificate,ingress     # TLS issued? ingress wired to traefik?
```

- **Pod `Pending`** → scheduling: the ARM node must be `Ready` (the only arm64 node) and
  have room for the two `ReadWriteOnce` PVCs.
- **502 from the domain** → pod not ready yet, or the cert isn't issued. Check the cert is
  `READY=True` and the pod is `1/1`.
