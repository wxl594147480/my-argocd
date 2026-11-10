# 演示用最小镜像：静态页面 + 版本文件。
# 版本文件由 CI 在构建前写入（见 .github/workflows/build-and-promote.yaml），
# 这样部署后访问 /version.txt 就能确认 Pod 里跑的到底是哪个 tag。
FROM nginx:1.27-alpine

COPY index.html /usr/share/nginx/html/index.html
COPY version.txt /usr/share/nginx/html/version.txt

EXPOSE 80
