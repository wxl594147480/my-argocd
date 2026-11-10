# env 配置：本地 / CI / 集群三层

> 这里讲的是**应用和 CI/CD 的环境变量**。
> 如果你问的是 lab 脚本那套参数（节点 IP、MetalLB 池、VPN），那是 `lab/conf/lab.env`，另一套东西。

## 0. 先定一条规则

**`.env` 永远不入库，入库的是 `.env.example`。**

- `.env` 只存在于开发机和 CI 的临时工作目录里；
- 敏感值（数据库密码、JWT key、PAT）只通过 Secret 注入，不写进任何被 Git 跟踪的文件；
- 同一个变量名在本地、CI、集群里保持一致，只是值不同——这样代码不用改，测试和线上跑的是同一套配置读取逻辑。

三层的关系：

```
本地开发              CI（GitHub Actions）           集群（K8s）
.env 文件      →      job env / secrets      →      ConfigMap + Secret
（不提交）            （进程环境变量）                （env / envFrom 注入）
```

## 1. 本地开发

仓库里提交模板，开发者复制一份：

```bash
cp .env.example .env
```

模板内容（`demo/app-repo/.env.example`，与 workflow 里 `services` 的端口、账号对齐）：

```dotenv
APP_ENV=local
LOG_LEVEL=debug
HTTP_PORT=8080

DATABASE_URL=postgres://demo:demo@127.0.0.1:5432/demo
VALKEY_URL=redis://127.0.0.1:6379/0
AMQP_URL=amqp://demo:demo@127.0.0.1:5672/
RABBITMQ_MANAGEMENT_URL=http://127.0.0.1:15672

# 本地假值。CI 和集群用 Secret 注入，绝不共用
JWT_SECRET=local-dev-only
```

配套的两个忽略文件必须一起提交：

- `.gitignore` 里加 `.env`、`.env.*`、`!.env.example`；
- `.dockerignore` 里也加 `.env`。**这一条比 .gitignore 更容易漏**：
  很多应用是 `COPY . .`，漏了就把本地数据库口令打进镜像层，换 tag 也删不掉。

本地起这三个依赖（和 CI 用同一组镜像/版本，避免“本地过、CI 挂”）：

```bash
docker run -d --name pg   -e POSTGRES_USER=demo -e POSTGRES_PASSWORD=demo \
  -e POSTGRES_DB=demo -p 5432:5432 postgres:17-alpine
docker run -d --name valkey -p 6379:6379 valkey/valkey:8-alpine
docker run -d --name mq   -e RABBITMQ_DEFAULT_USER=demo -e RABBITMQ_DEFAULT_PASS=demo \
  -p 5672:5672 -p 15672:15672 rabbitmq:4-management-alpine
```

## 2. CI（GitHub Actions）

按“敏感 / 非敏感”和“作用域”分三处放，不要一股脑塞进 `.env`：

| 放哪 | 放什么 | 例子 |
| --- | --- | --- |
| workflow 顶层 `env:` | 所有 job 共用、非敏感 | `REGISTRY`、`IMAGE_NAME`、`GITOPS_REPOSITORY` |
| job 级 `env:` | 只有这个 job 需要 | `DATABASE_URL`（test job） |
| `secrets.*` | 敏感 | `REGISTRY_PASSWORD`、`GITOPS_TOKEN` |
| `vars.*` | 仓库级可调参数（明文可见） | `DEMO_REGISTRY`、`RUNNER_LABEL` |

原则：**能在进程环境里给的，就不要落成文件。** workflow 里的 `env:` 本来就会注入到每个 step 的进程环境，测试框架直接读 `process.env` / `os.environ` 就行。

只有当测试框架**强制要求 `.env` 文件**（某些 dotenv 封装、`docker compose` 场景）时，才在 step 里临时生成：

```yaml
      - name: Materialize .env for test framework
        env:
          DATABASE_URL: ${{ env.DATABASE_URL }}
          VALKEY_URL: ${{ env.VALKEY_URL }}
          AMQP_URL: ${{ env.AMQP_URL }}
        run: |
          umask 077
          cat > .env <<EOF
          APP_ENV=ci
          DATABASE_URL=${DATABASE_URL}
          VALKEY_URL=${VALKEY_URL}
          AMQP_URL=${AMQP_URL}
          EOF
```

两个注意点：

- 不要 `cat .env`、不要 `echo $SECRET`——runner 日志会脱敏，但第三方 action 不一定；
- 生成的 `.env` 只活在这个 job 的 workspace 里，job 结束即销毁；**不要**把它 `actions/upload-artifact`。

## 3. 集群（K8s）

### 3.1 非敏感：ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-app-config
  namespace: demo-dev
data:
  APP_ENV: prod
  LOG_LEVEL: info
  VALKEY_URL: redis://valkey.demo-infra.svc.cluster.local:6379/0
  AMQP_URL: amqp://demo:demo@rabbitmq.demo-infra.svc.cluster.local:5672/
```

### 3.2 敏感：Secret（本仓库只允许 SealedSecret）

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: demo-app-secret
  namespace: demo-dev
spec:
  encryptedData:
    DATABASE_URL: AgBy...            # kubeseal 生成，随集群公钥走
    JWT_SECRET: AgCk...
```

- 生产/lab 有 sealed-secrets controller 时用 `kubeseal` 生成；
- lab 没装 controller 时只能手工 `kubectl create secret`（**不要提交**），
  或者先按 `infrastructure/sealed-secrets` 把 controller 装上；
- 同一个 Secret 的 key 名要和代码里的变量名一致，否则注入后是空的。

### 3.3 注入方式：`envFrom` vs `env`

```yaml
    spec:
      containers:
        - name: demo-app
          image: ghcr.io/wxl594147480/demo-app:sha-xxxxxxx
          # 整组注入：ConfigMap/Secret 里每个 key 变成一个环境变量
          envFrom:
            - configMapRef:
                name: demo-app-config
          # 单条注入：需要改名、或者只取 Secret 里的某一项时用它
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: demo-app-secret
                  key: DATABASE_URL
```

选择标准：

- key 多、不需要改名 → `envFrom`；
- 需要精确控制、或不同来源拼装 → `env` + `valueFrom`；
- **同名冲突时 `env` 覆盖 `envFrom`**，但别依赖这个规则，保持 key 不重名。

### 3.4 一个必踩的坑：改了 ConfigMap/Secret，Pod 不会重启

环境变量只在容器启动时读取一次。ArgoCD 同步了新的 ConfigMap，旧 Pod 里还是旧值，
表现为“Git 里明明改了，服务行为没变”。

三种解法：

1. 给 Pod 模板加 checksum 注解（Kustomize 没有内置，通常用 Helm 或手写）；
2. 在 ConfigMap 名后加版本后缀（`demo-app-config-v2`），改名即触发滚动；
3. 接受手工 `kubectl -n demo-dev rollout restart deploy/demo-app`（最简单，但会偏离 GitOps）。

选 1 或 2；3 只用于救火。

## 4. 优先级与命名

进程里最终生效的顺序（从高到低）：

```
kubectl 手工 env / K8s env > ConfigMap/Secret envFrom > 镜像 ENV > .env（应用自己加载的）
```

所以：**`.env` 只服务本地开发**，不要指望它在集群里生效；反过来，集群里也绝不会读到你本地的 `.env`。

命名约定：

- 全大写 + 下划线：`DATABASE_URL`、`VALKEY_URL`、`AMQP_URL`；
- 连接串统一用 URL 形式，本地/CI/集群只换 host；
- 不在镜像里 `ENV` 写任何环境相关的值（否则换环境要重新构建）。

## 5. 提交前检查

```bash
git check-ignore -v .env          # 必须命中 .gitignore
git ls-files | grep -E '(^|/)\.env$'   # 必须无输出
docker build -t tmp . && docker run --rm tmp env | grep -i secret  # 镜像里不该有敏感值
```
