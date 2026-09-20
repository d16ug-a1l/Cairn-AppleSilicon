<div align="center">

<img src="./README/banner.png" alt="Cairn Banner"/>

# Cairn-AppleSilicon
### 不止于 AI 渗透测试 —— 迈向通用状态空间搜索

<p>
  <a href="https://zc.tencent.com/hackathon" target="_blank" rel="noopener noreferrer">
    <img src="./README/tencent.png" alt="Tencent" height="55" />
  </a>
  <a href="https://zc.tencent.com/hackathon" target="_blank" rel="noopener noreferrer">
    <img src="./README/tch.png" alt="TCH" height="55" />
  </a>
  <a href="https://wiki.chainreactors.red" target="_blank" rel="noopener noreferrer">
    <img src="./README/c.png" alt="ChainReactors" height="45" />
  </a>
</p>

Cairn 是一个通用问题求解引擎。<br/>它不定义角色，不定义工作流。给定起点和终点，它在未知的状态空间中搜索一条路径。<br/>AI 渗透测试正是这样一类问题 —— 而且已经被验证可行。

<p>
  <a href="https://discord.gg/nDSy4NZVP" target="_blank" rel="noopener noreferrer">
    <img src="https://img.shields.io/badge/Discord-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord" />
  </a>
  <a href="https://x.com/le1xia0" target="_blank" rel="noopener noreferrer">
    <img src="https://img.shields.io/badge/X-000000?style=flat-square&logo=x&logoColor=white" alt="X" />
  </a>
</p>

</div>

> **关于本仓库**：Cairn-AppleSilicon 改编自 [oritera/Cairn](https://github.com/oritera/Cairn)，针对 **macOS Apple Silicon（M 系列芯片）** 环境进行适配。Docker 由 [OrbStack](https://orbstack.dev/) 提供 —— 开始前请先安装 OrbStack。Web 界面已汉化为简体中文。原项目请访问上游仓库。

<p align="center">
  <a href="https://www.bilibili.com/video/BV1a8R5BhEVi/" target="_blank" rel="noopener noreferrer">
    <img src="./README/cairn.png" alt="Cairn runtime screenshot" width="900" />
  </a>
</p>

## Cairn 是什么？

渗透测试本质上是在一个近乎无限的状态空间中进行的**有向搜索**：

- **起点**：已知（目标 IP、目标系统）
- **终点**：已定义（拿到 shell、捕获 flag）
- **路径**：未知

这种结构并非渗透测试独有。漏洞研究、数学证明、CTF 挑战 —— 任何起点明确、成功条件明确、中间路径未知的问题，都具有相同的形态。

Cairn 就是为这类问题而生的。渗透测试是它第一个被验证的领域。

引擎基于**黑板架构（Blackboard Architecture）**构建，维护一张显式的事实-意图图。只需要三个原语：

| 概念 | 含义 |
|---------|---------|
| **Fact（事实）** | 写入黑板的、已确认的客观发现 |
| **Intent（意图）** | 已声明但尚未执行的探索方向 |
| **Hint（提示）** | 随时注入的人类判断；Agent 下次读图时吸收 |

图从 `origin`（起点）向 `goal`（终点）生长。每条新 Fact 是一块垫脚石；每条 Intent 是迈向未知的一步。

Agent Worker 运行 OODA 循环 —— 观察全图、判断当前态势、决定下一步意图、执行探索 —— 并把发现作为新 Fact 写回黑板。Worker 没有固定角色：任务在运行时根据图的当前状态生成，而不是来自预定义的职责描述。

Agent 之间只通过共享黑板协调（趋化性，Stigmergy）。没有直接通信，没有信息孤岛。

## 实际运行效果

https://github.com/user-attachments/assets/e557b1ac-dda4-41cb-87dd-9d56dbf05133


## 工作原理

三类任务，全部由同一套 Worker 机制执行：

| 任务 | 做什么 | 产出 |
|------|-------------|--------|
| **Bootstrap（起步）** | 项目开始时直接尝试解题 | Fact + 可能的 Complete |
| **Reason（推理）** | 读全图：目标达成了吗？下一步该探索什么？ | Complete / 新 Intent / 空操作 |
| **Explore（探索）** | 认领一条 Intent，执行探索，报告发现 | 一条 Fact |

系统架构：

```
          ┌──────────────────────────────────┐
          │           Cairn Server           │
          │    Facts + Intents + Hints       │
          └─────────────────┬────────────────┘
                            │
                     Read / Write API
                            │
          ┌─────────────────┴────────────────┐
          │             Dispatcher           │
          │   Schedules tasks, manages       │
          │   containers, writes protocol    │
          └──────────┬───────────────┬───────┘
                     │               │
     ┌───────────────┴──┐     ┌──────┴──────────────┐
     │  Worker Container│     │  Worker Container   │
     │   (Project A)    │     │   (Project B)       │
     │  ┌────┐  ┌────┐  │     │  ┌────┐  ┌────┐     │
     │  │ W. │  │ W. │  │     │  │ W. │  │ W. │     │
     │  └────┘  └────┘  │     │  └────┘  └────┘     │
     └──────────────────┘     └─────────────────────┘
```

**Cairn Server** 只维护图的一致性。

**Cairn Dispatcher** 读取图、调度任务、创建和销毁 Worker 容器，是协议的唯一写入方。每个项目有独立的 Worker 容器；容器内多个 Agent Worker 并发运行。Agent Worker 只接收 prompt，返回结构化输出。

Worker 也可以不跑在容器里，而是直接运行在 Dispatcher 所在的宿主机上 —— **本地模式**，无需 Docker。见下文 [本地模式（无需 Docker）](#本地模式无需-docker)。

支持的 Worker 后端：**Claude Code**、**Codex**、**Pi**。

## 实战成绩

**腾讯云黑客松 · AI 渗透测试挑战赛 · 第二届**

610 支队伍 · 1,345 名参赛者 · 来自全国顶尖高校和安全厂商

| 指标 | 成绩 |
|--------|-------|
| 解题数 | **54 / 54 —— 全场唯一 AK（全部解出）** |
| 最终排名 | 第 3 名 |

> 该系统赛前从未经过测试。完整 pipeline 在比赛当天凌晨 4 点才首次跑通。没有训练，没有调优，没有领域专用工具。零 MCP 工具，零 RAG，零预定义 Agent 角色。

## 延伸阅读

- <a href="https://mp.weixin.qq.com/s/DlpEH7bVr0xi0VawPJs3XA" target="_blank" rel="noopener noreferrer">最强 AI 渗透测试 Agent：TCH 腾讯云黑客松智能渗透挑战赛唯一 AK 战队复盘</a>
- <a href="https://mp.weixin.qq.com/s/2rEqFLvkxvYWM3gW170C2w" target="_blank" rel="noopener noreferrer">无路之路：Cairn AI 从渗透测试到通用问题求解</a>

## 快速开始

**前置条件**
 
- macOS（Apple Silicon，M 系列芯片）
- [OrbStack](https://orbstack.dev/) —— 在 macOS 上提供 Docker 环境（仅容器执行模式需要；本地模式不需要）
- Python ≥ 3.12

### 一键构建（推荐）

```bash
./build.sh
```

自动完成：环境检查（缺失的 git / uv / OrbStack 自动通过 Homebrew 安装，并自动拉起 OrbStack）→ 安装 Python 依赖（PyPI 走阿里云镜像）→ 本地构建 arm64 worker 镜像（Kali 基础镜像走国内镜像站）→ 从 `dispatch.example.yaml` 创建 `dispatch.yaml` → 运行测试验证。构建完成后编辑 `dispatch.yaml` 填入 LLM 端点和 API key，然后 `./cairn.sh start` 即可启动。

以下为手动分步方式：

### 构建 worker 镜像
 
两种部署方式都需要 Worker 容器镜像。本项目仅构建 **arm64** 版本（上游 GHCR 预构建镜像仅有 amd64，故改为本地构建；Kali 基础镜像通过国内镜像站获取）：
 
```bash
docker build --platform=linux/arm64 \
  --build-arg KALI_BASE=docker.m.daocloud.io/kalilinux/kali-rolling:latest \
  -t ghcr.io/oritera/cairn-worker-container:latest ./container
```

镜像 tag 保持配置中使用的规范名称，`dispatch.yaml` 和 `cairn.sh` 无需改动。首次构建需下载数 GB 依赖，耗时较长。

创建本地 Dispatcher 配置，填入你的 LLM 端点和 API key：

```bash
cp dispatch.example.yaml dispatch.yaml
```
 
### Docker Compose（推荐）
 
拉取构建 Cairn 所需的基础镜像（根 `Dockerfile` 默认已使用南京大学 GHCR 镜像站，此步仅为预热）：
 
```bash
docker pull ghcr.nju.edu.cn/astral-sh/uv:python3.13-trixie
```
 
```bash
docker compose up --build
```
 
这会启动 `cairn-server`（端口 `8000`），并在其通过健康检查后启动 `cairn-dispatcher`。Dispatcher 挂载项目根目录的 `dispatch.yaml`，并通过宿主机 socket 连接 Docker。数据持久化到 `./datas/cairn/`。
 
### 手动方式
 
```bash
# 启动服务器
uv run --project cairn cairn serve
 
# 启动 Dispatcher
uv run --project cairn cairn dispatch --config dispatch.yaml
 
# 仅运行启动健康检查
uv run --project cairn cairn dispatch --config dispatch.yaml --startup-healthcheck-only
```

### 本地模式（无需 Docker）

Worker 可以不跑在每项目一个的容器里，而是直接运行在 Dispatcher 所在的宿主机上，复用本机已配置好的 `claude` / `codex` / `pi` CLI —— 无需 Docker，配置中也无需 API key。

```bash
cp dispatch.local.example.yaml dispatch.yaml

# 启动服务器
uv run --project cairn cairn serve

# 在安装了这些 CLI 并已登录的同一台宿主机上运行 Dispatcher
uv run --project cairn cairn dispatch --config dispatch.yaml
```

本地模式通过 `runtime.execution: local` 启用（见 `dispatch.local.example.yaml`）。启动时 Dispatcher 会检查每个配置的 Worker CLI 是否已安装且可运行，并提醒它们必须已登录。每个项目在 `local.workspace_root`（默认：Dispatcher 的当前目录）下获得一个独立工作目录。请直接在宿主机上运行 Dispatcher —— 不要放在 Docker 里 —— 因为 Agent 以你的用户权限运行且没有沙箱。

### 测试

无需 Docker 或真实模型端点，即可运行快速回归测试套件：

```bash
uv run --project cairn --group dev pytest
```

## 免责声明

Cairn 是一个通用问题求解引擎。虽然它支持渗透测试、CTF 解题、安全评估和漏洞研究工作流，但仅应在获得明确授权的环境中使用。

你对如何使用本项目负全部责任。在未获得所有者或运营者明确许可的情况下，不要将 Cairn 用于任何系统、网络、应用或数据。未经授权的安全测试、利用或数据访问可能违法并造成损害。

本项目的开发者和贡献者不为任何滥用、误用、损害、损失或法律后果背书或承担责任。使用本项目即表示你同意确保自己的行为符合所在司法辖区的所有适用法律、法规、合同义务以及专业或组织政策。

## Star History

<a href="https://www.star-history.com/#oritera/Cairn&Date" target="_blank" rel="noopener noreferrer">
  <img src="https://api.star-history.com/svg?repos=oritera/Cairn&type=Date" alt="Star History Chart" />
</a>

## ⚖️ 许可证
本项目基于 **GNU AGPLv3** 授权，供个人和教育用途使用。

**商业用途**：如果你希望在商业或专有环境中使用本项目而不承担 AGPL-3.0 的开源义务，**请联系上游作者获取商业许可证。**

**贡献**：提交 Pull Request 即表示你同意你的贡献可同时在 AGPL-3.0 和项目商业许可证下使用。
