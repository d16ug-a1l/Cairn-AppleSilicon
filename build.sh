#!/usr/bin/env bash
# Cairn 一键构建启动脚本：
#   探测项目是否已完成构建 —— 未构建则执行完整构建流程后启动；
#   已构建则直接使用本地镜像启动；启动失败时询问是否重新构建。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WORKER_IMAGE="ghcr.io/oritera/cairn-worker-container:latest"
APP_IMAGE="cairn-app"
KALI_BASE="docker.m.daocloud.io/kalilinux/kali-rolling:latest"
CONFIG="$ROOT/dispatch.yaml"
SERVER_URL="http://localhost:8000"
FORCE_BUILD=0

# 应用镜像基础镜像（astral-sh/uv）的候选镜像源，按优先级排列；逐个探测连通性，选第一个可用的
UV_IMAGE_REPO="astral-sh/uv"
UV_IMAGE_TAG="python3.13-trixie"
UV_MIRRORS=(
  "ghcr.nju.edu.cn"   # 南京大学 GHCR 镜像站（Dockerfile 默认值）
  "ghcr.linkos.org"   # linkos GHCR 镜像站
  "ghcr.io"           # 上游 GHCR（直连可用时最快）
)

[ "${1:-}" = "--force-build" ] && FORCE_BUILD=1

step() { echo; echo "── $1 ──"; }

# 交互式确认；非交互环境（无终端）按"否"处理
confirm() {  # confirm <提示语>
  if [ ! -t 0 ]; then
    return 1
  fi
  local reply
  read -r -p "$1 [y/N] " reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

# ── 环境检查（缺失的依赖自动通过 Homebrew 安装）──
check_env() {
  step "环境检查"
  if ! command -v brew >/dev/null 2>&1; then
    echo "[!] 未找到 Homebrew，请先安装: https://brew.sh"
    exit 1
  fi

  brew_install() {  # brew_install <命令> <brew 包名> [cask]
    local cmd="$1" pkg="$2" cask="${3:-}"
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "[+] ${cmd} 已安装"
      return 0
    fi
    echo "[*] 未找到 ${cmd}，使用 brew 安装 $pkg ..."
    if [ "$cask" = "cask" ]; then
      brew install --cask "$pkg"
    else
      brew install "$pkg"
    fi
  }

  brew_install git git
  brew_install uv uv
  echo "[+] uv $(uv --version | awk '{print $2}')"

  # OrbStack 提供 Docker 环境；docker CLI 由 OrbStack 安装时一并提供
  brew_install orb orbstack cask
  echo "[+] OrbStack 已安装"

  if ! docker info >/dev/null 2>&1; then
    echo "[*] Docker 未运行，尝试启动 OrbStack..."
    orb start >/dev/null 2>&1 || open -a OrbStack >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      docker info >/dev/null 2>&1 && break
      sleep 2
    done
    docker info >/dev/null 2>&1 || { echo "[!] Docker 启动超时，请手动启动 OrbStack 后重试"; exit 1; }
  fi
  echo "[+] Docker 已就绪（OrbStack）"
}

# ── 构建状态探测：worker 镜像（arm64）+ 应用镜像 + dispatch.yaml 三者齐备才算已构建 ──
is_built() {
  [ -f "$CONFIG" ] || return 1
  [ "$(docker image inspect "$WORKER_IMAGE" --format '{{.Architecture}}' 2>/dev/null || true)" = "arm64" ] || return 1
  docker image inspect "$APP_IMAGE" >/dev/null 2>&1
}

# ── 完整构建流程 ──
full_build() {
  step "安装 Python 依赖（PyPI 走阿里云镜像）"
  uv sync --project cairn --group dev --frozen
  echo "[+] 依赖安装完成"

  # 本项目仅构建 arm64；上游 GHCR 预构建镜像仅有 amd64，故本地构建
  step "构建 worker 镜像（arm64）"
  local existing_arch
  existing_arch="$(docker image inspect "$WORKER_IMAGE" --format '{{.Architecture}}' 2>/dev/null || true)"
  if [ "$FORCE_BUILD" -eq 0 ] && [ "$existing_arch" = "arm64" ]; then
    echo "[=] arm64 镜像 ${WORKER_IMAGE} 已存在，跳过（--force-build 可强制重建）"
  else
    if [ -n "$existing_arch" ] && [ "$existing_arch" != "arm64" ]; then
      echo "[*] 本地镜像为 ${existing_arch}，将重新构建 arm64 版本"
    fi
    echo "[*] 本地构建 arm64 worker 镜像（体积约 20GB，首次构建耗时较长，请耐心等待）..."
    docker build --platform=linux/arm64 \
      --build-arg KALI_BASE="$KALI_BASE" \
      -t "$WORKER_IMAGE" "$ROOT/container"
    echo "[+] arm64 镜像已就绪: ${WORKER_IMAGE}"
  fi

  step "初始化配置"
  if [ -f "$CONFIG" ]; then
    echo "[=] dispatch.yaml 已存在，跳过"
  else
    cp "$ROOT/dispatch.example.yaml" "$CONFIG"
    echo "[+] 已从 dispatch.example.yaml 创建 dispatch.yaml"
    echo "[!] 请编辑 dispatch.yaml，填入你的 LLM 端点和 API key"
  fi

  step "运行测试验证"
  uv run --project cairn --group dev pytest -q

  step "构建应用镜像（自动选择可用镜像源）"
  local uv_base=""
  local mirror url code elapsed start
  for mirror in "${UV_MIRRORS[@]}"; do
    url="https://${mirror}/v2/${UV_IMAGE_REPO}/manifests/${UV_IMAGE_TAG}"
    start=$(date +%s)
    code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
    elapsed=$(( $(date +%s) - start ))
    # 200 = 镜像清单可读；401 = 服务可达（匿名 token 由 docker 自行换取）
    if [ "$code" = "200" ] || [ "$code" = "401" ]; then
      echo "[+] ${mirror} 连通（HTTP ${code}，${elapsed}s），选用该镜像源"
      uv_base="${mirror}/${UV_IMAGE_REPO}:${UV_IMAGE_TAG}"
      break
    fi
    echo "[-] ${mirror} 不可达（HTTP ${code}，${elapsed}s），尝试下一个"
  done

  if [ -z "$uv_base" ]; then
    echo "[!] 所有镜像源均不可达，无法拉取应用基础镜像 ${UV_IMAGE_REPO}:${UV_IMAGE_TAG}"
    echo "[!] 请检查网络后重试，或手动执行: docker compose build --build-arg UV_BASE=<可用镜像>/${UV_IMAGE_REPO}:${UV_IMAGE_TAG}"
    exit 1
  fi

  echo "[*] 构建应用镜像 ${APP_IMAGE}（基础镜像: ${uv_base}）..."
  docker compose build --build-arg UV_BASE="$uv_base"
  echo "[+] 应用镜像已就绪: ${APP_IMAGE}"
}

# ── 使用本地镜像启动并等待 Server 就绪 ──
start_services() {
  step "启动服务"
  docker compose up -d

  echo -n "[*] 等待 Server 就绪..."
  for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "$SERVER_URL" 2>/dev/null; then echo " OK"; break; fi
    sleep 2
  done
  if ! curl -sf -o /dev/null "$SERVER_URL" 2>/dev/null; then
    echo " 失败"
    echo "[!] Server 未就绪，日志: docker compose logs cairn-server"
    return 1
  fi
  if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q '^cairn-dispatcher$'; then
    echo "[!] Dispatcher 未在运行，日志: docker compose logs cairn-dispatcher"
    return 1
  fi
  return 0
}

print_ready() {
  echo
  echo "[+] 全部就绪！"
  echo "    Web UI:      ${SERVER_URL}"
  echo "    查看状态:    ./cairn.sh status"
  echo "    跟踪日志:    ./cairn.sh logs"
  echo "    停止服务:    ./cairn.sh stop"
}

check_env

if [ "$FORCE_BUILD" -eq 0 ] && is_built; then
  echo
  echo "[=] 检测到项目已完成构建（worker 镜像 + 应用镜像 + dispatch.yaml），直接使用本地镜像启动"
else
  if [ "$FORCE_BUILD" -eq 1 ]; then
    echo
    echo "[*] --force-build：强制重新构建"
  else
    echo
    echo "[*] 检测到项目尚未完成构建，开始完整构建流程"
  fi
  full_build
fi

if start_services; then
  print_ready
  exit 0
fi

echo
if confirm "[?] 启动失败。是否重新构建后再试？"; then
  full_build
  start_services
  print_ready
else
  echo "[!] 已取消。排查后可手动执行 ./build.sh --force-build 重新构建"
  exit 1
fi
