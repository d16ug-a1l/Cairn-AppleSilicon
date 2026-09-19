#!/usr/bin/env bash
# Cairn 一键管理脚本：start / stop / restart / status / logs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$ROOT/.run"
SERVER_LOG="$RUN_DIR/server.log"
DISPATCHER_LOG="$RUN_DIR/dispatcher.log"
SERVER_URL="http://localhost:8000"
CONFIG="$ROOT/dispatch.yaml"
IMAGE="ghcr.io/oritera/cairn-worker-container:latest"

mkdir -p "$RUN_DIR"

is_running() { pgrep -f "$1" >/dev/null 2>&1; }

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

start() {
  [ -f "$CONFIG" ] || { echo "[!] 缺少 ${CONFIG}（参考 dispatch.example.yaml 创建）"; exit 1; }
  ensure_docker

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[!] 警告: worker 镜像 $IMAGE 不存在，任务执行会失败"
  fi

  if is_running "cairn serve"; then
    echo "[=] Server 已在运行"
  else
    nohup uv run --project cairn cairn serve >"$SERVER_LOG" 2>&1 &
    echo $! >"$RUN_DIR/server.pid"
    echo -n "[*] 等待 Server 就绪..."
    for _ in $(seq 1 30); do
      if curl -sf -o /dev/null "$SERVER_URL" 2>/dev/null; then echo " OK"; break; fi
      sleep 1
    done
    curl -sf -o /dev/null "$SERVER_URL" 2>/dev/null || { echo " 失败，日志: $SERVER_LOG"; exit 1; }
  fi

  if is_running "cairn dispatch"; then
    echo "[=] Dispatcher 已在运行"
  else
    nohup uv run --project cairn cairn dispatch --config "$CONFIG" >"$DISPATCHER_LOG" 2>&1 &
    echo $! >"$RUN_DIR/dispatcher.pid"
    sleep 3
    if is_running "cairn dispatch"; then
      echo "[+] Dispatcher 已启动（日志: ${DISPATCHER_LOG}）"
    else
      echo "[!] Dispatcher 启动失败，日志: $DISPATCHER_LOG"
      exit 1
    fi
  fi

  echo "[+] 全部就绪，Web UI: $SERVER_URL"
}

stop() {
  local stopped=0
  if is_running "cairn dispatch"; then
    pkill -f "cairn dispatch" && echo "[+] Dispatcher 已停止" && stopped=1
  fi
  if is_running "cairn serve"; then
    pkill -f "cairn serve" && echo "[+] Server 已停止" && stopped=1
  fi
  rm -f "$RUN_DIR"/server.pid "$RUN_DIR"/dispatcher.pid
  [ "$stopped" -eq 0 ] && echo "[=] 没有运行中的 Cairn 进程"

  # 清理残留的 worker 容器
  local workers
  workers=$(docker ps -aq --filter "ancestor=$IMAGE" 2>/dev/null || true)
  if [ -n "$workers" ]; then
    echo "[*] 发现残留的 worker 容器，清理中..."
    echo "$workers" | xargs docker rm -f >/dev/null 2>&1 || true
    echo "[+] worker 容器已清理"
  fi
}

status() {
  echo "── 进程 ──"
  if is_running "cairn serve"; then echo "Server:     运行中"; else echo "Server:     未运行"; fi
  if is_running "cairn dispatch"; then echo "Dispatcher: 运行中"; else echo "Dispatcher: 未运行"; fi
  echo "── 服务 ──"
  curl -s -o /dev/null -w "Web UI:     HTTP %{http_code} ($SERVER_URL)\n" --max-time 5 "$SERVER_URL" 2>/dev/null || echo "Web UI:     不可达"
  echo "── Docker ──"
  if docker info >/dev/null 2>&1; then
    docker image inspect "$IMAGE" --format "镜像:       已就绪 ({{.Os}}/{{.Architecture}}, 本地构建)" 2>/dev/null || echo "镜像:       不存在"
    local n
    n=$(docker ps -q --filter "ancestor=$IMAGE" 2>/dev/null | wc -l | tr -d ' ')
    echo "worker 容器: ${n} 个运行中"
  else
    echo "Docker:     未运行"
  fi
}

logs() {
  touch "$SERVER_LOG" "$DISPATCHER_LOG"
  tail -f "$SERVER_LOG" "$DISPATCHER_LOG"
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 2; start ;;
  status)  status ;;
  logs)    logs ;;
  *)
    echo "用法: $0 {start|stop|restart|status|logs}"
    echo "  start   一键启动（自动拉起 OrbStack/Docker、Server、Dispatcher）"
    echo "  stop    一键关闭（停止进程并清理残留 worker 容器）"
    echo "  restart 重启"
    echo "  status  查看运行状态"
    echo "  logs    实时跟踪日志（Ctrl+C 退出）"
    exit 1
    ;;
esac
