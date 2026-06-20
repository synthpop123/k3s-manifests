# 把一个小 k3s 集群当成代码来管：push-based 而非 GitOps-pull

之前写过用 [Komodo + Renovate 给一堆 Docker Compose 服务搭 GitOps 流水线](https://lkwplus.com/blog/komodo-gitops)：集群外跑一个 Komodo，从仓库自动部署，push 一下就 reconcile，Renovate 监测上游镜像、发现新版本提升级 PR。那套东西的核心是"集群里有个常驻进程，主动从 Git 拉状态"。

后来把一部分服务挪到了一个四节点的 k3s 小集群上——Oracle 的一台 arm64 当 control-plane，两台 amd64 当 agent，外加一台腾讯云新加坡节点。到了 Kubernetes 上，顺着惯性最容易想到的就是 Argo CD 或 Flux，把那套 pull 式 GitOps 原样搬过来。但这次我走了相反的方向：仓库仍是 single source of truth，可集群从不读它，所有改动都从控制机 push 进去。

这篇记录这套做法本身，以及它为什么对这个规模合适、代价又落在哪里。它不是要论证 push 比 pull 好——对一个跑了二十多个服务、多人协作的环境，结论很可能相反——而是想说清楚：在四个节点、一个人维护的前提下，把 controller 这一层拿掉之后，剩下的东西要怎么搭才不塌。

## push 和 pull 的分界

先把两种模型摆在一起，差别其实只在一个问题上：**谁主动发起那次同步。**

| | pull（Argo CD / Flux） | push（这个仓库） |
| --- | --- | --- |
| 谁在 reconcile | 集群里的 controller，持续运行 | 控制机上的一条命令，手动触发 |
| 集群是否读 Git | 是，controller 直连仓库 | 否，集群完全不知道 GitHub 的存在 |
| 凭据放在哪 | 集群里要有 repo 的读权限、可能还有解密用的私钥 | 全在控制机：kubeconfig、SSH key、age 私钥 |
| drift 怎么发现 | controller 自动对账并纠偏 | 自己跑 `make diff` 查，不会自动纠偏 |
| 改坏了的拦截点 | controller / admission webhook | push 之前的 `make lint` |

pull 模型的好处是真实的：自动对账意味着有人手贱直接 `kubectl edit` 改了线上，controller 会把它纠回来；新机器接管也简单，controller 一跑就收敛。代价是集群里多了一个常驻组件，而且这个组件需要能读到仓库、有时还得能解密 secret——也就是说，**集群本身成了一个需要被授权、被信任的 Git 客户端。**

对四个节点来说，我更在意的是另一头：

- 集群里少一个常驻 controller，就少一处要升级、要排障、要给权限的东西。k3s 本身已经够小，我不想在上面再叠一层 GitOps 平台。
- 凭据全留在控制机。集群里没有任何能回连 GitHub 的东西，仓库可以大大方方公开（这个仓库就是公开的），泄露面只剩下控制机一台。
- 一个挂掉的集群不会把 GitOps 也一起拖下水。解密密钥不在集群里，所以"集群没了"和"还能不能恢复"是两件独立的事——恢复只需要这个仓库加一把 age 私钥。

这套取舍能成立，前提是把 pull 模型免费送的两样东西自己补上：**自动对账**换成手动的 drift 检查，**集群侧的拦截**换成 push 前的本地校验。下面几节基本都在讲这两件事怎么补。

## 仓库是 live 状态的镜像，靠 diff 来验证

push 模型最容易退化的地方，是仓库和集群慢慢对不上：仓库里躺着几个早就删掉的 app，或者线上被临时改过、却没回写进 Git。pull 模型靠 controller 强行保证两者一致；push 模型没有这个力，只能靠两条约定顶着。

第一条是约定本身：`apps/` 下一个文件夹对应一个**真实部署着**的 app，不放任何"打算以后上"的东西。服务上线就加文件夹，下线就删，仓库始终是线上的镜像而不是愿望清单。

第二条是让这条约定可被检验——`make diff`，它把"如果现在每个 apply 都跑一遍会改动什么"预览出来，但什么都不应用：

```
helm diff   →  本地 chart pin + values.yaml   vs   集群里存着的 release
kubectl diff →  仓库里的 manifest             vs   线上对象
ssh arm cat …/traefik-config.yaml | diff …   →  仓库里的 traefik 配置 vs ARM 上那份
```

最后一行值得留意：traefik 的配置不是用 kubectl 管的（原因见下一节），所以 diff 也得特地 ssh 到 ARM 节点上把那份文件抓回来比。输出里某一段是空的，就说明那块没有 drift。这条命令是这套 push 模型里"对账"的全部——它不纠偏，只告诉我哪里偏了，纠不纠、怎么纠由我决定。

## 文件放在哪个目录，决定它怎么到达集群

pull 模型里"怎么应用"基本是统一的，controller 包办。push 模型里这件事是显式的，而且这个仓库故意用**目录**来编码它：一个文件该用什么机制 apply，看它躺在哪儿就知道。

| 路径 | 机制 | 怎么应用 |
| --- | --- | --- |
| `apps/<name>/`（kustomize app，如 wallos） | Kustomize | `kubectl apply -k apps/<name>/` |
| `apps/multica/values.yaml`、`apps/supabase/values.yaml` | Helm | `helm upgrade --install <release> <chart> -f values.yaml` |
| `platform/cert-manager/`、`platform/headlamp/` | Helm + 附带的 plain manifest | `helm upgrade …` 再 `kubectl apply -f …` |
| `platform/traefik/traefik-helmchartconfig.yaml` | k3s auto-deploy | **scp 到 ARM** 的 `/var/lib/rancher/k3s/server/manifests/`，**不是 kubectl** |
| `node-config/<node>.config.yaml` | k3s 节点配置 | 渲染后**经 ssh** 写进 `/etc/rancher/k3s/config.yaml`，再重启 k3s，**不是 kubectl** |

前三种是常规的 kubectl / helm。后两种是真正的坑，因为它们看着像普通 manifest、却**不能**用 kubectl apply：

- traefik 那份是个 `HelmChartConfig`。k3s 会监视 server 节点上的 auto-deploy 目录并自动 reconcile 里面的内容，所以正确的"应用"动作是把文件 scp 到那个目录，k3s 自己接手。仓库里的副本只是 source-of-truth 和重建依据，对它 `kubectl apply` 不会报错，但也什么都不会发生。
- `node-config/` 下是 k3s 节点的 `config.yaml`，配的是 k3s 进程本身（比如 `node-external-ip`——跨云组网时每个节点都得把自己的公网 IP 显式告诉 k3s）。这层比任何 Kubernetes 对象都低，只能写文件加重启进程。

这些命令我没有让人去背，而是收进了 `Makefile`，每个 target 都是底层那条 `kubectl` / `helm` / `scp` / `ssh` 命令的薄包装：

```bash
make app APP=wallos       # kubectl apply -k apps/wallos/
make multica              # helm upgrade --install + 它的 cert 和 backup CronJob
make traefik              # scp 那份 ARM-pin 配置到 server 节点
make node-config NODE=sg  # 渲染 sg 的 k3s 配置、推上去、重启 k3s-agent
make platform             # 按正确顺序把所有平台组件过一遍
```

把"怎么 apply"显式写进目录和 Makefile，某种程度上是在补 controller 的课：pull 模型里这套知识沉淀在 controller 的实现里，push 模型里它得沉淀在仓库结构和 `make` target 里，否则就只活在我脑子里，过半年就忘。

## 一切 pin 到 ARM 节点

集群里几乎所有东西都带着 `nodeSelector: kubernetes.io/arch: arm64`，被钉在那台 ARM 节点上。这不是随手写的，是几个事实叠出来的硬约束：

- ARM 节点是 control-plane（server），其余三台是 agent。
- 默认存储用的是 k3s 自带的 `local-path`，它是**节点本地**的——PV 落在哪台机器的磁盘上，数据就只在那台机器上。
- 于是任何带 PVC 的 stateful pod 都必须回到它数据所在的节点。一旦 pod 被调度到别的节点，它要么挂载不上原来的 PV，要么挂上一个空的新目录。

所以这个 nodeSelector 是 load-bearing 的：它保证 wallos 的 SQLite、multica 的 pgvector、supabase 的 Postgres 重启后都回到 ARM，找回自己的盘。traefik 也一并钉在 ARM，因为公网入口要稳定落在 control-plane 这一台上。代价是 ARM 节点成了单点——但对一个家用规模的集群，我接受用"数据和入口都在一台已知的机器上"换掉一整套分布式存储的复杂度。新加坡那台 agent 额外打了 `location=singapore` 的 taint，默认不接活，只跑明确容忍它的 workload。

## 密钥只以密文进 Git

push 模型在 secret 这件事上反而比 pull 干净，因为它把一个本来很拧巴的问题直接绕开了。

pull 模型下，集群要自己从 Git 拿到配置，那加密的 secret 也得能在集群里解开——于是要么上 Sealed Secrets（集群里跑个 controller 持有私钥），要么给 Argo 配个解密插件。无论哪种，**解密能力都得住进集群**。

push 模型不需要。既然 apply 是从控制机发起的，解密也在控制机做就行。这个仓库用的是 SOPS + age：

- 所有 secret 值——外加并不算机密、但也不想公开的 `NODE_IP_*` 节点公网 IP——都存在 `secrets.enc.env` 里。这个文件**是提交进 git 的**：变量名和注释明文可读，每个值是一坨 `ENC[...]` 密文。age 的 recipient 钉在 `.sops.yaml`，对应的私钥只在控制机和密码管理器里有备份。
- `scripts/apply-secrets.sh` 在内存里 `sops -d` 解密（密钥不在就直接硬失败，而不是默默跳过），再 `kubectl create … --dry-run=client | apply` 把 Secret 对象建出来，幂等。明文从不落盘。脚本里一个 app 一段，没填的 app 自动跳过。
- manifest 不直接读环境变量——Kubernetes 不会这么做——而是通过 `secretKeyRef` 引用这些建好的 Secret。

这套之所以贴合 push 模型，是因为它**纯客户端**：集群里没有任何解密组件，一个 dead cluster 不会把解密密钥一起带走。灾备路径因此短得只有一句话——这个仓库，加上那把 age 私钥。

有了"明文绝不进库"这条线，就能用机器去守它。`make lint` 里有一步专门扫 `secrets.enc.env`，逐行确认每个值要么是 `ENC[...]` 要么为空，发现明文就让构建失败。这也顺带把节点公网 IP 一并保护了：仓库公开，但 IP 只以密文出现，apply 时才由 `make node-config` 渲染进节点配置模板。

## CI 只做校验，永远碰不到集群

pull 模型里有 controller 和 admission webhook 在集群边上把关，一个写坏的 manifest 进不了线上。push 模型把这道关挪到了更前面——push 之前的本地校验。这个仓库的 CI（GitHub Actions）每次 push 就跑一条 `make lint`，仅此一条：

- `lint-manifests`：把 `apps/` 和 `templates/` 下每个 kustomization build 出来，连同所有 plain manifest 一起喂给 `kubeconform -strict`。
- `lint-helm`：用各自 pin 的版本和 `values.yaml` 把那四个 Helm chart `helm template` 渲染出来，同样过 `kubeconform -strict`。
- `lint-scripts`：`shellcheck` 扫 `scripts/`。
- `lint-secrets`：上一节那个明文扫描。

`-strict` 会拒绝未知字段，校验又是对着集群真实的 Kubernetes 版本（`1.36.1`，跟集群一起升）做的，所以一个 YAML 拼写错误、或者 values 和 chart 对不上，会在 CI 里就炸掉，而不是拖到 apply 那一刻才发现。

这里有个对 push 模型来说要紧的设计：**CI 在结构上就够不到集群。**GitHub 那边没有 kubeconfig、没有 SSH key、没有 age 私钥，所以哪怕 CI 流程被改坏或被人钻了空子，它能做的最坏的事也只是"校验不通过"，绝不可能动到线上。pull 模型把信任放在集群里那个能读 Git 的 controller 上；push 模型把信任收在控制机，CI 退化成一个纯粹的、无害的 linter。对一个公开仓库，这种"CI 天生无权限"的性质让人睡得踏实。

## 把版本钉死

push 模型没有 controller 持续把集群拉回某个声明的状态，所以"我以为没动过的东西"必须真的没动过，否则 drift 会悄悄累积。落到实处就是：**任何一次 re-run 都不能静默升级任何东西。**

四个 Helm release 的 chart 版本全部 pin 在 `Makefile` 的变量里（`cert-manager v1.20.2`、`headlamp 0.42.0`、`multica 0.3.19`、`supabase 0.5.6`），kustomize app 的镜像 tag pin 在各自的 `deployment.yaml`，绝不用 `:latest`。于是 `make platform` 跑十遍，结果都一样，不会因为上游发了新版就把集群顺手带上去。

升级是一个**显式**动作：`make bump APP=<name>` 把可选的新版本列出来、或把指定版本写进对应的 pin，改动落进一行 diff，过一遍 CI，再由我决定哪天 apply。换句话说，升级和我手改一行配置走的是同一条路——都得先改 Git、再 push 到集群。这正是 pull 模型里 Renovate 那套"改 tag 也要过 PR"的思路，只是这里没有机器人替我提 PR，bump 这个动作由我手动发起。

## stateful app 都带一个夜间备份

local-path 是节点本地存储，没有副本，ARM 节点的盘坏了数据就没了。所以每个 stateful app 都配了一个夜间备份的 CronJob（`apps/<name>/backup.yaml`），把状态 dump 出来传到 Cloudflare R2，保留 30 天，三个 app 的时间错开在 03:10 / 03:30 / 03:50（Asia/Shanghai）。

以 multica 那个为例，它分两段、共用一个 emptyDir：

- init 容器用 `postgres:17-alpine` 的 `pg_dump` 客户端，走集群网络连到 `multica-postgres:5432` 把库 dump 下来、gzip 压好。这里特地开了 `set -o pipefail`——不然 `pg_dump` 失败、`gzip` 却退出 0，整个 Job 会假装成功。
- main 容器把 uploads PVC 以只读方式挂进来打成 tar（同节点的 RWO 多挂载在 local-path 上是允许的），再用 rclone 把两个文件 copy 到 `r2:<bucket>/backups/multica/`，顺手删掉 30 天前的旧件。

R2 的凭据走的还是前面那套 secret 流程：`BACKUP_R2_*` 在 `secrets.enc.env` 里，经 `apply-secrets.sh` 变成每个 app namespace 下的 `backup-r2` Secret，它的几个 key 直接拼成一个无需 config 文件的 rclone "r2" remote（通过 `envFrom` 注入），非机密的 `TYPE`/`PROVIDER` 则写在 CronJob 的 manifest 里。备份这件事是这套模型里少数"集群自己定时干"的活——但它只往外写 R2，不读 Git，不破坏"集群从不回连 GitHub"这条线。

## 这套做法的边界

把上面几块连起来看，push-based 不是"砍掉 GitOps"，而是把 GitOps 平时由 controller 兜着的几件事，拆开来分别交给：仓库结构（怎么 apply）、`make diff`（对账）、`make lint` 加 CI（拦截）、SOPS（解密）、Makefile 里的 version pin（防漂移）。controller 那一层的复杂度没有凭空消失，而是被摊薄成了一组约定和一个 `Makefile`。

它合适的前提很具体：节点数个位数、基本一个人维护、能接受 drift 靠手动 `make diff` 发现而非自动纠偏。一旦节点和服务多起来、或者要多人协作、要审计每一次实际下发，那个常驻 controller 的价值就会盖过它的成本，该上 Argo / Flux 就上。对现在这个四节点的小集群，我还乐意自己当那个 controller。

完整的代码在 [synthpop123/k3s-manifests](https://github.com/synthpop123/k3s-manifests)，每个子目录都有自己的 README，写清了各自的 apply 步骤和 bootstrap 顺序。
