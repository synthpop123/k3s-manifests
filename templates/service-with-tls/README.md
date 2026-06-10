# Template: a stateless HTTPS service

The standard 4-piece recipe — **Namespace + Deployment + Service + Ingress** — for
exposing one service at `https://<name>.lkwplus.com` with an auto-issued cert.

## Use it

```bash
# 1. Copy into apps/ under your app's name
cp -r templates/service-with-tls apps/blog

# 2. Replace the placeholders (rename "myapp" -> your app, set the host & image)
#    edit apps/blog/*.yaml  (change name/namespace "myapp", host "myapp.lkwplus.com", image)

# 3. Deploy the whole folder
kubectl apply -k apps/blog/

# 4. Add a Cloudflare DNS record:  <name>  CNAME  arm.lkwplus.com  (grey cloud / DNS only)

# 5. Wait for the cert, then test
kubectl get certificate -n blog        # READY=True
curl -s https://blog.lkwplus.com
```

## Add persistence (stateful app)

1. Add a `pvc.yaml` (see the storage notes in the top-level README), e.g. a 5Gi
   `PersistentVolumeClaim` using the default `local-path` StorageClass.
2. Uncomment the `pvc.yaml` line in `kustomization.yaml`.
3. Uncomment the `volumeMounts` / `volumes` blocks in `deployment.yaml`.

> `local-path` data is **node-local**. Keep `nodeSelector: kubernetes.io/arch: arm64`
> so the pod always returns to ARM where its data lives.
