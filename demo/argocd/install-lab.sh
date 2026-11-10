#!/usr/bin/env bash
# lab 专用 ArgoCD 安装脚本。
#
# 与生产 infrastructure/argocd 的区别：
#   - 不带 Ingress / gts-prod 证书（lab 没有 cert-manager）
#   - 打开 server.insecure，UI 走 HTTP，port-forward 或 argocd.lab 直连
#   - 打开 kustomize.buildOptions=--enable-helm（本仓库的 helmCharts 目录要用）
#
# 用法（在能访问 lab 集群的机器上执行）：
#   sudo bash install-lab.sh                  # 在 110 上直接跑
#   KUBECTL=kubectl bash install-lab.sh       # 已有 kubeconfig 时
#   WITH_INGRESS=1 sudo bash install-lab.sh   # 顺便建 argocd.lab 的 Ingress
set -euo pipefail

KUBECTL="${KUBECTL:-}"
if [ -z "${KUBECTL}" ]; then
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL=kubectl
  elif [ -x /var/lib/rancher/rke2/bin/kubectl ]; then
    KUBECTL=/var/lib/rancher/rke2/bin/kubectl
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
  else
    echo "找不到 kubectl；请设置 KUBECTL=/path/to/kubectl" >&2
    exit 1
  fi
fi

VERSION="${ARGOCD_VERSION:-v3.3.0}"

echo "==> kubectl: ${KUBECTL}"
echo "==> ArgoCD: ${VERSION}"

echo "==> 1/6 创建 namespace"
"${KUBECTL}" create namespace argocd --dry-run=client -o yaml | "${KUBECTL}" apply -f -

echo "==> 2/6 安装清单（server-side，CRD 注解较大，客户端 apply 可能失败）"
"${KUBECTL}" apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${VERSION}/manifests/install.yaml"

echo "==> 3/6 打开 HTTP 模式 + --enable-helm"
"${KUBECTL}" -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
"${KUBECTL}" -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm"}}'

echo "==> 4/6 重启 server / repo-server 使配置生效"
"${KUBECTL}" -n argocd rollout restart deploy/argocd-server deploy/argocd-repo-server
for d in argocd-server argocd-repo-server; do
  "${KUBECTL}" -n argocd rollout status "deploy/${d}" --timeout=300s
done

if [ "${WITH_INGRESS:-0}" = "1" ]; then
  echo "==> 5/6 创建 argocd.lab Ingress（无 TLS）"
  "${KUBECTL}" apply -f - <<'EOF'
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
else
  echo "==> 5/6 跳过 Ingress（WITH_INGRESS=1 可创建 argocd.lab）"
fi

echo "==> 6/6 状态"
"${KUBECTL}" -n argocd get pods

echo
echo "=============================="
echo " 地址  : kubectl -n argocd port-forward svc/argocd-server 8080:80"
echo "         → http://localhost:8080   （或 http://argocd.lab）"
echo " 用户名: admin"
if PASSWORD="$("${KUBECTL}" -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)" && [ -n "${PASSWORD}" ]; then
  echo " 密码  : ${PASSWORD}"
else
  echo " 密码  : initial-admin-secret 已不存在（改过密码），用现有密码登录"
fi
echo "=============================="
echo
echo "下一步："
echo "  1) 配 GitOps 仓库凭据（demo/README.md 第 5 节）"
echo "  2) 装 ARC（demo/README.md 2.2）"
echo "  3) apply demo/gitops/argocd-app.yaml"
