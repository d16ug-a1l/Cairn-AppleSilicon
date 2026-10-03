#!/usr/bin/env bash
# Cairn 管理脚本（Docker Compose）：start / stop / restart / status / logs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WORKER_IMAGE="ghcr.io/oritera/cairn-worker-container:latest"
APP_IMAGE="cairn-app"
CONFIG="$ROOT/dispatch.yaml"
SERVER_URL="http://localhost:8000"

ensure_docker() {
  if docker info >/dev/null 2>&1; then return 0; fi
  echo "[*] Docker 未运行，尝试启动 OrbStack..."
  orb start >/dev/null 2>&1 || open -a OrbStack >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "[!] Docker 启动超时，请手动启动 OrbStack 后重试"
  exit 1
}

# 交互式确认；非交互环境（无终端）按"否"处理
confirm() {  # confirm <提示语>
  if [ ! -t 0 ]; then
    return 1
  fi
  local reply
  read -r -p "$1 [y/N] " reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

is_built() {
  [ -f "$CONFIG" ] || return 1
  [ "$(docker image inspect "$WORKER_IMAGE" --format '{{.Architecture}}' 2>/dev/null || true)" = "arm64" ] || return 1
  docker image inspect "$APP_IMAGE" >/dev/null 2>&1
}

start() {
  ensure_docker

  if ! is_built; then
    echo "[!] 项目尚未完成构建（需要 worker 镜像 + 应用镜像 + dispatch.yaml）"
    if confirm "[?] 是否现在运行 build.sh 完成构建？"; then
      exec "$ROOT/build.sh"
    fi
    echo "[!] 已取消。请先执行 ./build.sh 完成构建"
    exit 1
  fi

  docker compose up -d

  echo -n "[*] 等待 Server 就绪..."
  for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "$SERVER_URL" 2>/dev/null; then echo " OK"; break; fi
    sleep 2
  done
  if ! curl -sf -o /dev/null "$SERVER_URL" 2>/dev/null; then
    echo " 失败"
    echo "[!] Server 未就绪，日志: docker compose logs cairn-server"
    if confirm "[?] 启动失败。是否运行 build.sh 重新构建后再试？"; then
      exec "$ROOT/build.sh" --force-build
    fi
    exit 1
  fi
  echo "[+] 全部就绪，Web UI: ${SERVER_URL}"
}

stop() {
  ensure_docker
  docker compose down
  echo "[+] cairn-server / cairn-dispatcher 已停止"

  # 清理残留的 worker 容器（dispatcher 按项目启动，compose down 不会触及）
  local workers
  workers=$(docker ps -aq --filter "ancestor=$WORKER_IMAGE" 2>/dev/null || true)
  if [ -n "$workers" ]; then
    echo "[*] 发现残留的 worker 容器，清理中..."
    echo "$workers" | xargs docker rm -f >/dev/null 2>&1 || true
    echo "[+] worker 容器已清理"
  fi

  if lsof -nP -i :8000 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[!] 警告: 8000 端口仍被以下进程占用:"
    lsof -nP -i :8000 -sTCP:LISTEN | tail -n +2
  fi
}

status() {
  echo "── 容器 ──"
  docker compose ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null || echo "compose 不可用"
  echo "── 服务 ──"
  curl -s -o /dev/null -w "Web UI:     HTTP %{http_code} (${SERVER_URL})\n" --max-time 5 "$SERVER_URL" 2>/dev/null || echo "Web UI:     不可达"
  echo "── 镜像 ──"
  docker image inspect "$APP_IMAGE" --format "应用镜像:   已构建 ({{.Os}}/{{.Architecture}})" 2>/dev/null || echo "应用镜像:   未构建"
  docker image inspect "$WORKER_IMAGE" --format "worker 镜像: 已就绪 ({{.Os}}/{{.Architecture}}, 本地构建)" 2>/dev/null || echo "worker 镜像: 不存在"
  echo "── worker 容器 ──"
  local n
  n=$(docker ps -q --filter "ancestor=$WORKER_IMAGE" 2>/dev/null | wc -l | tr -d ' ')
  echo "运行中:     ${n} 个"
}

logs() {
  docker compose logs -f
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 2; start ;;
  status)  status ;;
  logs)    logs ;;
  *)
    echo "用法: $0 {start|stop|restart|status|logs}"
    echo "  start   启动服务（自动拉起 OrbStack/Docker；未构建时询问是否先构建）"
    echo "  stop    停止服务并清理残留 worker 容器"
    echo "  restart 重启"
    echo "  status  查看运行状态"
    echo "  logs    实时跟踪日志（Ctrl+C 退出）"
    exit 1
    ;;
esac
