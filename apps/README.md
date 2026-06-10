# apps

One directory per deployed application (≈ one Kubernetes namespace per app).

## Deployed apps

| App | URL | What it is |
|---|---|---|
| [`wallos/`](./wallos) | https://wallos.lkwplus.com | Self-hosted subscription tracker (stateful) |
| [`multica/`](./multica) | https://multica.lkwplus.com | AI-native issue tracker — Helm: backend + frontend + Postgres (stateful) |
| [`supabase/`](./supabase) | https://supabase.lkwplus.com | Self-hosted Supabase backend platform — Helm: 12-component stack + Postgres (stateful) |

Keep this table and the `apps/` folders a faithful mirror of live cluster state — add a
row when you deploy something, remove it (and the folder) when you uninstall. Platform
components (cert-manager, Headlamp, Traefik) live separately in [`../platform/`](../platform).

Most apps are Kustomize (`make app APP=<name>`); `multica/` and `supabase/` are the exceptions —
upstream Helm charts deployed with `make multica` / `make supabase` (see their READMEs).

## Add an app

```bash
cp -r ../templates/service-with-tls ./blog   # pick a name = its namespace
# edit ./blog/*.yaml (rename myapp -> blog, set host & image)
kubectl apply -k ./blog/
```

Then add the Cloudflare DNS record and wait for the certificate. See
[`../templates/service-with-tls/README.md`](../templates/service-with-tls/README.md).
