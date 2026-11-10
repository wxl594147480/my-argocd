# demo/：GitHub Actions → ghcr.io → ArgoCD 全链路验证

> 这是 **lab 环境**（`192.168.1.110/111/117`）的验证用目录，不是生产组件。
> 清单里的 `repoURL` 指向演示仓库 `wxl594147480/my-argocd`（公开仓库），
> 不涉及原来的 `Mangania/K8s-services`——那个仓库不要动。
> 只有你手工把 `demo/gitops/argocd-app.yaml` apply 到 lab 集群，才会产生 `demo-dev` 这个应用。

## 0. 要验证的四段

```
① git push 应用仓库
        │
        ▼
② GitHub Actions（lab 里的 ARC runner，label=arc-runner-lab）
        │  service containers：postgres / valkey / rabbitmq → 跑测试
        │  docker build → smoke test → docker push
        ▼
③ ghcr.io：ghcr.io/wxl594147480/demo-app:sha-<commit>
        │  kustomize edit set image + git commit/push（只改 Git）
        ▼
④ GitOps 仓库 my-argocd: demo/gitops/overlays/dev
        │
        ▼
   lab ArgoCD 轮询到新 commit → 同步 demo-dev → kubelet 从 ghcr.io 拉镜像
```

这条链路的验收标准只有一句话：**`curl /version.txt` 返回的 `sha-xxxxxxx`
与 `git log -1` 的 commit 一致**。只看 ArgoCD 显示 `Synced` 不够——镜像错了它也是 Synced。

## 1. 目录与职责

| 路径 | 属于哪个仓库 | 作用 |
| --- | --- | --- |
| `demo/app-repo/` | **应用仓库**（如 `wxl594147480/demo-app`） | 整个目录复制过去：Dockerfile、页面、workflow、测试依赖探测脚本 |
| `demo/app-repo/.env.example` | 应用仓库 | 本地/CI 的变量模板（`.env` 本身不入库） |
| `demo/app-repo/.github/workflows/build-and-promote.yaml` | 应用仓库 | 测试、构建、推送、回写 Git |
| `demo/gitops/` | **本仓库**（my-argocd） | Kustomize base/overlay + ArgoCD Application |
| `demo/gitops/runner/` | 本仓库 | lab 专用的 ARC controller + runner set（label `arc-runner-lab`） |
| `demo/gitops/overlays/dev/kustomization.yaml` | 本仓库 | CI 只改这一处 `newTag` |
| [demo/ENV.md](ENV.md) | 本仓库 | env 在本地 / CI / 集群三层怎么配 |

为什么拆两个仓库：CI 仓库的写权限只应该覆盖“自己的代码 + 镜像”，
部署状态的写权限应该单独收口。这样回滚就是 revert 一个 commit，
而不是 `kubectl set image`——后者在开了 `selfHeal` 的集群上会被立刻打回。

> 注意：`demo/app-repo/.github/workflows/` 放在本仓库里**不会被执行**，
> GitHub 只读取仓库根目录的 `.github/workflows/`。它只是给应用仓库用的模板。

## 2. 前置检查

先在 lab 上逐项确认，缺哪项先补哪项，不要跳：

| 依赖 | 检查命令 | 期望 | 不满足时 |
| --- | --- | --- | --- |
| 集群 | `kubectl get nodes` | 3 台 Ready | `lab/README.md` 阶段 0–1 |
| ingress-nginx | `kubectl -n ingress-nginx get svc` | EXTERNAL-IP `192.168.1.200` | 阶段 3 |
| 镜像仓库 | 默认 ghcr.io，无需安装 | 包设为 public，否则 ImagePullBackOff | 只有用私有仓库时才需要 Nexus |
| ARC runner | GitHub 组织 → Settings → Actions → Runners | 有 `arc-runner-lab` 在线 | 2.2 / 2.3 |
| ArgoCD | `kubectl -n argocd get pods` | 全部 Running | 第 3 节 |

### 2.1 lab 里的 ARC 有两个坑

`actions-runner/` 下的清单是给生产用的，直接搬到 lab 会有两处不成立：

1. `github-secret-sealed.yaml` 是用**生产集群**的 Sealed Secrets 公钥加密的，lab 解不开。
   lab 要直接建明文 Secret（只在 lab 用，绝不入库）：

   ```bash
   kubectl -n arc-runners create secret generic github-app-secret \
     --from-literal=github_app_id=<APP_ID> \
     --from-literal=github_app_installation_id=<INSTALLATION_ID> \
     --from-file=github_app_private_key=app.pem
   ```

2. `values.yaml` 里 runner 镜像指向 `cr.miguocomics.co/actions-runner:2.338.0`。
   lab 如果拉不到，需要先把它 retag 推到集群能访问的仓库，再改 `values.yaml` 的 image。

确认 runner 真的能接活：在应用仓库里跑一次只含 `echo` 的 workflow，
`runs-on: arc-runner-lab` 能变绿再继续。

### 2.2 安装 ARC（走 ArgoCD，推荐）

> 这一步依赖第 3 节（ArgoCD）。仓库是公开的，不需要第 5 节的凭据（私有化时才配）。

`demo/gitops/runner/` 里是 lab 专用的 controller + runner set，和生产的 `actions-runner/`
互不影响。关键差别是 **label = `arc-runner-lab`**：如果 lab 也用 `arc-runner-set`，
两个集群会抢同一个 GitHub 作业队列，作业跑到哪台机器上就不确定了。

> 如果 lab 之前已经用生产清单装过 `arc-runner-set`，不必再装这套：
> 把仓库变量 `RUNNER_LABEL` 设成 `arc-runner-set` 即可。

1. 先建 GitHub App 凭据。Secret 必须先于 runner set 存在，否则 Pod 会一直起不来：

   ```bash
   kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n arc-runners create secret generic github-app-secret \
     --from-literal=github_app_id=<APP_ID> \
     --from-literal=github_app_installation_id=<INSTALLATION_ID> \
     --from-file=github_app_private_key=app.pem
   ```

2. 先 controller，再 runner set（runner set 引用 controller 创建的 `arc-gha-rs-controller`）：

   ```bash
   kubectl apply -f demo/gitops/runner/controller/argocd-app.yaml
   kubectl -n arc-systems get pods   # 等 arc-gha-rs-controller-xxx Running 再继续
   kubectl apply -f demo/gitops/runner/runner-set/argocd-app.yaml
   ```

3. 验证：

   ```bash
   kubectl -n arc-runners get autoscalingrunnersets,pods
   # GitHub 组织 → Settings → Actions → Runners：出现 arc-runner-lab（Idle 表示已连上集群）
   ```

> ArgoCD 渲染 `helmCharts` 需要 `kustomize.buildOptions: --enable-helm`，
> 第 3 节安装时已经一并配好，少了这一步这两个 Application 会报
> `must specify --enable-helm`。

### 2.3 不用 ArgoCD 时（helm 备用）

不要用裸 `helm install`：runner 里必须带 dind，否则 `docker build` 直接不可用。
用 lab 专用 values（已包含 dind 和 HTTP registry 放行）：

```bash
# 1) controller：release 名是 arc，ServiceAccount 名才是 arc-gha-rs-controller
helm install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  -n arc-systems --create-namespace --version 0.13.1

# 2) runner set：release 名 = label，必须是 arc-runner-lab
helm install arc-runner-lab \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -n arc-runners --create-namespace --version 0.13.1 \
  -f demo/gitops/runner/runner-set/values.yaml \
  --set minRunners=1
```

前提是 lab 能拉到 `values.yaml` 里的两个镜像
（`cr.miguocomics.co/actions-runner:2.338.0`、`mirrors.miguocomics.co/docker/library/docker:29.9.1-dind`）。
拉不到就先在生产侧 retag 推到集群能访问的仓库，再改 `values.yaml` 的 image 字段。

## 3. 在 lab 安装 ArgoCD

> 不要直接 `kubectl apply -k infrastructure/argocd`：那份是生产版，
> Ingress 绑定了 `argocd.infra.miguocomics.co` + `cert-manager.io/cluster-issuer: gts-prod`
> 且强制 HTTPS 跳转。lab 没有 cert-manager，TLS Secret 永远不会生成，
> 结果就是一直 302 到一个没有证书的地址。lab 按下面最小安装。

> 想少敲命令：`sudo bash demo/argocd/install-lab.sh`
> （加 `WITH_INGRESS=1` 会顺手建 `argocd.lab` 的 Ingress；脚本末尾直接打印初始密码）。
> 下面是分步说明，脚本做的事和它完全一致。

```bash
kubectl create namespace argocd
# 用 --server-side：install.yaml 里的 CRD 注解很大，客户端 apply 可能报 metadata.annotations too long
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml
```

打开 HTTP 模式（否则要走 TLS，port-forward 和 Ingress 都得多一层）：

```bash
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server
```

本仓库的 `helmCharts` 目录（runner 的 controller / runner set）还要开这个开关，
否则 ArgoCD 渲染时报 `must specify --enable-helm`：

```bash
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm"}}'
kubectl -n argocd rollout restart deploy/argocd-repo-server
kubectl -n argocd rollout status deploy/argocd-repo-server
```

初始密码与登录：

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

访问方式二选一：

```bash
# 方式一：port-forward（不依赖 DNS）
kubectl -n argocd port-forward svc/argocd-server 8080:80
# → http://localhost:8080，用户名 admin

# 方式二：lab 入口（Windows hosts 里已有 argocd.lab → 192.168.1.200）
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
```

## 4. 镜像仓库：默认用 ghcr.io（不需要 Nexus）

lab 里没有 Nexus，这套默认推到 **GitHub Container Registry**：

```
ghcr.io/wxl594147480/demo-app:sha-<commit>
```

不用装任何东西，workflow 用 `GITHUB_TOKEN` 登录（`packages: write` 已在权限里）。

### 唯一要手动做的一步：把 package 设成 public

ghcr 的 package 默认是私有的，kubelet 匿名拉不到，会 `ImagePullBackOff`（Events 里是 `unauthorized`）。
第一次 push 成功后：

1. GitHub 个人主页 → **Packages** → `demo-app`
2. 右下 **Package settings** → Danger Zone → **Change visibility** → Public

> 不想公开也行：建一个带 `read:packages` 的 PAT，在 `demo-dev` 里建 `docker-registry` Secret，
> 再给 Deployment 加 `imagePullSecrets`。lab 图省事，直接 public。

### 换回私有仓库（以后装了 Nexus / 用生产 registry）

改两个仓库变量即可，workflow 会自动走 secrets 登录分支：

| 变量 | 值 |
| --- | --- |
| `DEMO_REGISTRY` | `192.168.1.117:5001` 或 `cr.miguocomics.co` |
| `DEMO_IMAGE_NAME` | `demo-app` |

同时把 `demo/gitops/overlays/dev/kustomization.yaml` 的 `newName` 改成同样的仓库地址。
如果仓库是 **HTTP**（lab Nexus），还要：

- 三台节点写 `/etc/rancher/rke2/registries.yaml` 的 `mirrors` + HTTP endpoint，重启 `rke2-server`；
- 给 dind 加 `--insecure-registry=192.168.1.117:5001`（[values.yaml](gitops/runner/runner-set/values.yaml) 里留了注释）。

## 5. 给 ArgoCD 配 GitOps 仓库凭据（公开仓库可跳过）

`wxl594147480/my-argocd` 是公开仓库，ArgoCD 可以匿名 clone，**这一节可以先跳过**。

只有把仓库改成私有时才需要：

```bash
kubectl -n argocd create secret generic my-argocd-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/wxl594147480/my-argocd.git \
  --from-literal=username=<GitHub 用户名> \
  --from-literal=password=<PAT> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret my-argocd-repo \
  argocd.argoproj.io/secret-type=repository --overwrite
```

PAT 只需要 **读** 权限（classic：`repo`；fine-grained：Contents = Read）。
写权限是 CI 用的那个 token，两者不要混用。

## 6. 准备应用仓库

1. 在 GitHub 建一个空仓库，例如 `wxl594147480/demo-app`。
2. 把 `demo/app-repo/` 里的**全部内容**（含 `.github/`、`.env.example`、`.gitignore`、`.dockerignore`）复制到仓库根目录，push。
   Windows 下用 `Copy-Item -Recurse -Force demo\app-repo\* <目标目录>\`，
   复制完确认 `.github/workflows/build-and-promote.yaml` 真的在（资源管理器默认隐藏点目录）。
   本地开发时 `cp .env.example .env`，变量怎么分层见 [ENV.md](ENV.md)。
3. 本地先渲染一次，不连集群：

   ```bash
   kustomize build demo/gitops/overlays/dev | grep image:
   # 初始应渲染出 ghcr.io/wxl594147480/demo-app:sha-0000000
   ```

4. 配置 Secrets / Variables：

| 名称 | 类型 | 值 |
| --- | --- | --- |
| `GITOPS_TOKEN` | Secret | PAT，对 `my-argocd` 有 **Contents: Read and write** |
| `REGISTRY_USERNAME` | Secret | 仅私有仓库需要（Nexus 的 CI 用户） |
| `REGISTRY_PASSWORD` | Secret | 仅私有仓库需要 |
| `RUNNER_LABEL` | Variable | `arc-runner-lab`（用生产 runner 时改成 `arc-runner-set`） |

> ghcr.io 走 `GITHUB_TOKEN`，不需要 `REGISTRY_USERNAME` / `REGISTRY_PASSWORD`。
> 换私有仓库时再加这两个 Secret，并设置 `DEMO_REGISTRY` / `DEMO_IMAGE_NAME` 变量（见第 4 节）。

> `GITOPS_TOKEN` 用 classic PAT 时勾 `repo`；用 fine-grained 时选
> `wxl594147480/my-argocd` + Contents 读写。若 main 开了分支保护，要把该用户/App 加进 bypass 名单，
> 否则 promote 会 403。

## 7. workflow 怎么设计的

文件：`demo/app-repo/.github/workflows/build-and-promote.yaml`

### 7.1 四个 job 的分工

| job | 做什么 | 为什么单独拆 |
| --- | --- | --- |
| `meta` | 用 `docker/metadata-action` 算出 tag（`sha-<7位>`，打 `v*` 时再加一个语义化 tag） | tag 规则只写一处，build 和 promote 引用同一份输出，不会出现“推的 tag 和写的 tag 不一致” |
| `test` | 用 `services:` 起 PostgreSQL / Valkey / RabbitMQ → 等健康 → 跑测试 | 测试依赖随 job 生灭，不占集群 PVC，也不需要在集群里长期维护中间件 |
| `build` | `docker build`（多 tag）→ 把 tag 写进 `version.txt` → 起容器自检 → 推送 | 推送前就验证镜像可运行，坏镜像不进仓库 |
| `promote` | checkout GitOps 仓库 → 改 overlay 的 `newTag` → commit + push | 只在 main / `v*` 上跑；PR 完全不写 Git |

### 7.2 关键设计点

- **tag 用 `sha-<commit>`，不用 `latest`。**
  ArgoCD 靠“Git 里的期望镜像”和“集群里实际镜像”做 diff，可变 tag 会让 diff 失去意义，
  也没法精确回滚到某一次构建。
- **PR 只构建不推送**：`smoke test` 和 `push` 两个 step 都用
  `if: github.event_name != 'pull_request'` 挡住，PR 不会污染镜像仓库，也不会改 Git；
  但 `test` job 在 PR 上照常跑，这是它存在的意义。
- **promote 不做 `kubectl set image`。**
  集群开了 `selfHeal`，手工改会被立刻拉回；而且那样集群状态就和 Git 漂移了。
  Git 是唯一事实源，改 Git 才是“发布”。
- **幂等提交**：`git diff --cached --quiet` 命中时直接退出，
  重复跑同一个 commit 不会产生空提交。
- **并发控制**：`concurrency` 按 ref 分组，PR 间可取消，main 不取消，
  避免两个构建同时改同一行 `newTag`。
- **先用普通 `docker build`，不用 buildx。**
  lab 的 dind 拉 `moby/buildkit` 镜像可能失败，`setup-buildx-action` 会卡在准备阶段。
  链路稳定后再换 buildx + `type=registry` 缓存，收益是跨次构建复用基础镜像层。
- **自检比对**：镜像里的 `version.txt` 就是本次 tag，
  smoke test 校验 `served == sha-<GITHUB_SHA 前 7 位>`，防止“构建成功但内容不对”。

### 7.3 为什么第一版不用 Image Updater

生产的 UAT 链路是 CI 只推镜像、Image Updater 按 `newest-build` 回写 Git。
这层自动化在“第一次跑通”时反而难排错：分不清是 CI 没推、Updater 没扫到、还是写回权限不对。

所以这里先用 CI 显式回写，把链路跑绿；之后再切 Image Updater 只需要：

1. 删掉（或禁用）`promote` job；
2. 在 lab 装 `infrastructure/argocd-image-updater`；
3. 给 `demo-dev` 建一个 `ImageUpdater` CR（`imageName: ghcr.io/wxl594147480/demo-app`，
   策略 `newest-build`，`writeBackTarget: kustomization:demo/gitops/overlays/dev`）。

### 7.4 测试依赖：service containers，不是集群中间件

测试代码要连 PostgreSQL / Valkey / RabbitMQ 时，最省事、最隔离的做法是 GitHub Actions
的 `services:`——它们由 runner 的 Docker（ARC 里的 dind sidecar）启动，和 job 同生共死，
端口映射到 `127.0.0.1`，测试代码不需要感知 CI：

| 依赖 | 镜像 | 端口 | 健康检查 |
| --- | --- | --- | --- |
| PostgreSQL | `postgres:17-alpine` | 5432 | `pg_isready` |
| Valkey | `valkey/valkey:8-alpine` | 6379 | `valkey-cli ping` |
| RabbitMQ | `rabbitmq:4-management-alpine` | 5672 / 15672 | `rabbitmq-diagnostics -q ping` |

为什么这样比“在集群里装一套中间件给 CI 用”更好：

- **隔离**：每次 job 都是空库，测试之间不会互相污染，不需要清理脚本。
- **生命周期**：job 结束容器即删，不需要 PVC、备份、升级和凭据轮换。
- **并行**：多个 runner 同时跑，各自一套，不抢端口。
- **成本**：只在跑测试的几十秒里占内存。

什么时候才值得装进集群（StatefulSet + Longhorn）：

- 测试要连的是**部署后的服务**（端到端），不是代码里的单元/集成测试；
- 需要跨 job 保留数据（例如跑完迁移再验一次）；
- 多条流水线要共用一套实例，且能接受互相影响。

这两个坑几乎一定会踩：

1. **dind 直连 Docker Hub**。lab 节点上配的镜像站只对 containerd 生效，dind 不继承。
   拉不到时给 dind 加 `--registry-mirror`（`demo/gitops/runner/runner-set/values.yaml` 里有注释），
   或把三个镜像同步到可访问的仓库后改 `image:`。
2. **健康检查必须写**。`services:` 只保证容器“started”，不保证“ready”；
   没有 `--health-cmd` 时测试经常在 Postgres 初始化到一半时就开始连，表现为随机失败。
   `scripts/test-deps.sh` 还会再做一次 TCP 探测兜底。

连接串通过 job 级 `env` 注入（`DATABASE_URL` / `VALKEY_URL` / `AMQP_URL`），
测试代码只读环境变量；本地开发时把同一组变量指向 `localhost` 即可。

## 8. 首次跑通

### 8.1 顺序 A：先 CI 后 CD（推荐，排错面最小）

1. 装 ArgoCD（第 3 节）；仓库是公开的，第 5 节可跳过。
2. 装 ARC（2.2），确认 GitHub Runners 页面里 `arc-runner-lab` 是 Idle。
3. push 应用仓库 → Actions 里 `meta → test → build → promote` 依次变绿。
4. 确认镜像：GitHub 个人主页 → **Packages** → `demo-app`，应出现 `sha-xxxxxxx` 的 tag。
5. 确认回写：在 `my-argocd` 的本地克隆里 `git log --oneline -3`，应有一条
   `chore(demo): 镜像升级到 sha-xxxxxxx`。
6. `kubectl apply -f demo/gitops/argocd-app.yaml`。
7. 看 `demo-dev` 从 `Progressing` 变 `Synced / Healthy`。

### 8.2 顺序 B：先 CD 后 CI（顺便看自愈）

先 apply Application。此时 overlay 里的 `sha-0000000` 不存在，
Pod 会是 `ImagePullBackOff`、ArgoCD 显示 `Degraded`——**这是预期**。
然后跑一次 workflow，约 1–3 分钟后 ArgoCD 拉到新 commit 自动同步，Pod 自愈。
这个顺序能把“Git 改了 → ArgoCD 自动收敛”演示得最清楚。

> 默认 `syncPolicy.automated` 已经打开。如果想让第一次同步可控，
> 先把 `automated` 注释掉，用 UI 手动 Sync 一次。

## 9. 验收

```bash
# 集群里的镜像 tag
kubectl -n demo-dev get deploy demo-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# 实际返回的版本（应该等于上面的 sha-*）
curl -s -H 'Host: demo.lab' http://192.168.1.200/version.txt; echo

# 与 Git 对齐
git log -1 --format='%h %s'

# ArgoCD 视角
kubectl -n argocd get application demo-dev \
  -o jsonpath='{.status.sync.status} {.status.health.status}'; echo
```

四条一致才算链路通。再补一个“漂移自愈”测试：

```bash
kubectl -n demo-dev scale deploy/demo-app --replicas=3
# 约 3 分钟后回到 1（overlay 里 replicas: 1）——证明 selfHeal 生效
```

## 10. 故障排查

| 现象 | 最可能原因 | 排查 |
| --- | --- | --- |
| workflow 一直 queued | runner label 不匹配 / ARC 离线 / 与生产抢队列 | 仓库 Settings → Actions → Runners；`kubectl -n arc-runners get pods`；确认 `RUNNER_LABEL=arc-runner-lab` |
| test job 卡在 `Initialize containers` | dind 拉不到 `postgres` / `valkey` / `rabbitmq` 镜像 | 看 job 日志里的 pull 错误；给 dind 加 `--registry-mirror` 或换可用的镜像源 |
| test 随机失败、连不上库 | 没写 health check，测试跑在依赖就绪前 | 确认 `services.*.options` 里有 `--health-cmd`；保留 `test-deps.sh` |
| `services` 端口连不上 | job 没走 dind / 端口没映射 | 确认 runner 模板里 dind 正常、`ports:` 有写；`docker ps` 看容器 |
| `docker login` 401 | 私有仓库用户名/密码错，或没权限 | 只在用私有仓库时出现；检查 Secret 和 Nexus 角色 |
| push 报 `unauthorized`（ghcr） | workflow 缺 `packages: write` 或仓库设置禁用了 Actions | 看 7.x 的 `permissions`；仓库 Settings → Actions → General |
| `ImagePullBackOff` + `unauthorized`（ghcr） | package 还是 private，kubelet 匿名拉不到 | Packages → demo-app → Package settings → Change visibility → Public |
| `ImagePullBackOff` + `not found` | overlay 的 `newName` 和实际镜像不一致 | `kubectl -n demo-dev describe pod`，对照 workflow 的 `images:` 输出 |
| build 拉 `nginx` 失败 | dind 直连 Docker Hub，未走节点镜像站 | 给 dind 加 `--registry-mirror`，或把基础镜像换成可用的镜像 |
| promote 403 | `GITOPS_TOKEN` 无写权限 / 分支保护 | 用该 token 手工 `git push` 复现 |
| ArgoCD 报 `ComparisonError` | 仓库凭据 url 不匹配、path 写错 | `kubectl -n argocd logs deploy/argocd-repo-server` |
| ArgoCD 报 `repository not found` / 拉取超时 | lab 到 `github.com` 不通（110 的 GitHub 路由没起）或 PAT 无权读 | 在节点上 `curl -sI https://github.com`；对照 `lab/VPN.md` |
| Pod `ImagePullBackOff` | kubelet 未配 insecure registry / 镜像名错 | `kubectl -n demo-dev describe pod` 看 Events |
| `Synced` 但访问 404 | Ingress host / Service selector 不一致 | 对照 `demo.lab`、`app: demo-app` |
| 版本号对不上 | 镜像 tag 与构建内容不一致 | 看 workflow 的 `Stamp build version` 与 smoke test 日志 |

## 11. 后续演进

1. **加生产 overlay**：`demo/gitops/overlays/prod`，副本数 2，
   `newTag` 由人改——复刻“UAT 自动、生产人工”的分界。
2. **切 Image Updater**：见 7.3。
3. **PR 预览环境**：ApplicationSet + Pull Request generator，每个 PR 一个临时 namespace。
4. **供应链**：trivy 扫描 + cosign 签名，再在 ArgoCD 侧加验签策略。
5. **通知**：复用 `.github/workflows/actions-runner-build.yaml` 里的企业微信 webhook 写法。
6. **集群内中间件**：如果要做端到端测试（连部署后的服务），再按 7.4 的判断把
   PostgreSQL / Valkey / RabbitMQ 装成 StatefulSet + Longhorn。

## 12. 与生产的差异

| 项 | 生产 | 本 demo |
| --- | --- | --- |
| 镜像仓库 | `cr.miguocomics.co`（HTTPS，匿名拉取） | ghcr.io（默认，package 需 public） |
| GitOps 仓库 | `Mangania/argocd-web-services` | `wxl594147480/my-argocd` 的 `demo/` 目录 |
| tag 回写 | UAT 由 Image Updater 自动，生产人工 | CI 直接改 `newTag` |
| ArgoCD 暴露 | Ingress + `gts-prod` 证书 | 无 TLS，`argocd.lab` 或 port-forward |
| 环境隔离 | `account-center` / `account-center-uat` | 只有 `demo-dev` |
| CI runner | 集群内 ARC，label `arc-runner-set` | lab ARC，label `arc-runner-lab`（避免抢队列） |
| 测试依赖 | 由各应用 workflow 自行准备 | `services:` 三个容器，随 job 销毁 |

**结论**：链路结构一致，差异只在“谁有权限改 Git”和“入口怎么暴露”。
把这两点想清楚，生产的发版流程就能直接套用。
