# node-config

These are **node-level k3s config files**, not Kubernetes manifests. They are not
applied with `kubectl`. Each file is a template for `/etc/rancher/k3s/config.yaml`
on the corresponding node, which the k3s service reads at startup.

Currently each only sets `node-external-ip` so the node's public IP shows up in
`kubectl get nodes -o wide`.

**The IPs themselves never enter git.** Every file carries a `__NODE_IP__`
placeholder; `make node-config` fills it from the matching `NODE_IP_*` variable in
the git-ignored `.env` and streams the rendered file straight onto the node — no
rendered copy is written locally.

| File | Node (SSH alias) | Cluster node name | `.env` variable |
|---|---|---|---|
| `arm.config.yaml`  | `arm`  | `k3s-ora-arm-1`     | `NODE_IP_ARM` |
| `amd1.config.yaml` | `amd1` | `k3s-ora-amd-1`     | `NODE_IP_AMD1` |
| `amd2.config.yaml` | `amd2` | `k3s-ora-amd-2`     | `NODE_IP_AMD2` |
| `sg.config.yaml`   | `sg`   | `k3s-tencent-sg-1`  | `NODE_IP_SG` |

## Apply a change to a node

```bash
make node-config NODE=sg     # render from .env, push to the node, restart k3s
```

Which is equivalent to:

```bash
# Example for the sg node (a pure agent has no /etc/rancher/k3s dir by default):
ssh sg 'mkdir -p /etc/rancher/k3s'
sed "s/__NODE_IP__/<the NODE_IP_SG value>/" node-config/sg.config.yaml \
  | ssh sg 'cat > /etc/rancher/k3s/config.yaml'
ssh sg 'systemctl restart k3s-agent'     # server node (arm) -> systemctl restart k3s
```

> After restart the `EXTERNAL-IP` takes ~60–90s to appear (cloud-controller reconcile).
