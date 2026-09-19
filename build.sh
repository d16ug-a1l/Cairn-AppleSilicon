#!/usr/bin/env bash
# Cairn 一键构建脚本：环境检查 → 依赖安装 → worker 镜像准备 → 配置初始化 → 测试验证
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MIRROR_IMAGE="ghcr.nju.edu.cn/oritera/cairn-worker-container:latest"
IMAGE="ghcr.io/oritera/cairn-worker-container:latest"
PLATFORM="linux/amd64"
CONFIG="$ROOT/dispatch.yaml"
FORCE_PULL=0

[ "${1:-}" = "--force-pull" ] && FORCE_PULL=1

step() { echo; echo "── $1 ──"; }

# 1. 环境检查
step "1/5 环境检查"
if ! command -v uv >/dev/null 2>&1; then
  echo "[!] 未找到 uv，请先安装: brew install uv（或参考 https://docs.astral.sh/uv/）"
  exit 1
fi
echo "[+] uv $(uv --version | awk '{print $2}')"

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

# 2. 安装 Python 依赖（PyPI 走阿里云镜像，见 cairn/pyproject.toml）
step "2/5 安装 Python 依赖"
uv sync --project cairn --group dev --frozen
echo "[+] 依赖安装完成"

# 3. 准备 worker 镜像（南京大学 GHCR 镜像站拉取，retag 为规范名称）
step "3/5 准备 worker 镜像"
if [ "$FORCE_PULL" -eq 0 ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[=] 镜像 $IMAGE 已存在，跳过（--force-pull 可强制更新）"
else
  echo "[*] 通过国内镜像站拉取 worker 镜像（约数 GB，请耐心等待）..."
  docker pull --platform="$PLATFORM" "$MIRROR_IMAGE"
  docker tag "$MIRROR_IMAGE" "$IMAGE"
  echo "[+] 镜像已就绪并标记为 $IMAGE"
fi

# 4. 初始化配置文件
step "4/5 初始化配置"
if [ -f "$CONFIG" ]; then
  echo "[=] dispatch.yaml 已存在，跳过"
else
  cp "$ROOT/dispatch.example.yaml" "$CONFIG"
  echo "[+] 已从 dispatch.example.yaml 创建 dispatch.yaml"
  echo "[!] 请编辑 dispatch.yaml，填入你的 LLM 端点和 API key"
fi

# 5. 运行测试验证
step "5/5 运行测试验证"
uv run --project cairn --group dev pytest -q

echo
echo "[+] 构建完成！"
echo "    启动服务: ./cairn.sh start"
echo "    Web UI:   http://localhost:8000"
