#!/usr/bin/env bash
# 等待 workflow 里 services: 启动的三个依赖就绪。
# 只做 TCP 可达性检查，不依赖 psql / redis-cli / rabbitmqadmin 等客户端，
# 因此 runner 镜像里不需要额外装工具。
set -euo pipefail

wait_for() {
  local name="$1" host="$2" port="$3"
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      echo "[ok] ${name} ${host}:${port}"
      return 0
    fi
    sleep 1
  done
  echo "[fail] ${name} ${host}:${port} 不可达" >&2
  return 1
}

wait_for postgres      127.0.0.1 5432
wait_for valkey        127.0.0.1 6379
wait_for rabbitmq      127.0.0.1 5672
wait_for rabbitmq-mgmt 127.0.0.1 15672
