# AGENTS.md

面向在本仓库工作的 AI 编码代理的指南。阅读本文件的读者默认对本项目一无所知。

## 项目概览

本仓库是 **Cairn-AppleSilicon**，改编自 [oritera/Cairn](https://github.com/oritera/Cairn)，针对 **macOS Apple Silicon（M 系列芯片）** 环境适配：Docker 由 [OrbStack](https://orbstack.dev/) 提供，worker 镜像在本地构建 arm64 版本，Web 界面已汉化为简体中文。除本 fork 特有内容外，其余均适用上游项目及其文档。

Cairn 是一个通用问题求解引擎（已在 AI 渗透测试 / CTF 场景验证）。它将目标导向的探索建模为黑板上的有向"事实-意图"图：**Fact（事实，已确认的发现，节点）**、**Intent（意图，已声明的探索，边）**、**Hint（提示，外部人类/Agent 输入，不在图内）**。图从 `origin` 向 `goal` 生长。Agent 之间只通过共享图协调（趋化性，Stigmergy），各自运行 OODA 循环。

仓库包含两个交付物：

- **`cairn/`** —— Python 应用（包名 `cairn`，版本 0.2.1），包含：
  - **Cairn Server**（`src/cairn/server/`）—— FastAPI + SQLite 事实源。只维护图的一致性，不做任何推理。提供协议 API 和静态 Web UI（`server/static/index.html`，基于 Cytoscape 的图视图，本 fork 中 UI 文本为简体中文）。
  - **Cairn Dispatcher**（`src/cairn/dispatcher/`）—— 客户端执行器：读图、调度任务、管理每个项目的 worker 容器，是**协议的唯一写入方**。Agent 从不直接调用 Cairn API。
- **`container/`** —— worker 容器镜像（Kali Linux + 渗透测试工具 + 固定版本的 `claude` / `codex` / `pi` Agent CLI + 无头 Chromium），本地 tag 为 `ghcr.io/oritera/cairn-worker-container:latest`。Dockerfile 的镜像/代理构建参数（`KALI_BASE`、`KALI_MIRROR`、`PIP_INDEX_URL`、`GH_PROXY`、`NPM_REGISTRY`）默认使用国内镜像站（daocloud、阿里云、npmmirror、gh-proxy.com）—— 传空值即可用上游源构建；Dockerfile 支持多架构（`TARGETARCH`），但本 fork 只构建 arm64（上游 GHCR 发布的镜像仅有 amd64）。`container/AGENTS.md` 和 `container/.agents/skills/` 会烤进镜像，作为面向 Agent 的环境简报（中文，CTF 导向）。

三类任务全部由同一套 worker 机制执行：`bootstrap`（项目开始时直接尝试解题）、`reason`（读全图，决定 complete / 新 intent / 空操作）、`explore`（认领一条 intent，执行探索，报告一条 fact）。支持的 worker 后端：**Claude Code**、**Codex**、**Pi**，外加用于离线测试的 **mock**。

## 技术栈

- Python ≥ 3.12，使用 **uv** 管理（`uv_build` 后端，`uv.lock` 已锁定）。
- 依赖：FastAPI、uvicorn、click、PyYAML、docker（SDK）、requests；配置/模型使用 pydantic。dev 组：pytest、httpx。
- 存储：纯 SQLite（`server/db.py`），WAL 模式，启动时幂等建表；默认数据库在 `~/.local/share/cairn/cairn.db`（可用 `cairn serve --db-path` 覆盖）；附件文件本体存在 db 同级 `attachments/<project_id>/` 目录，不入库。
- 无 linter/formatter 配置（无 ruff/black/mypy），无 CI 配置 —— 保持与现有代码风格一致即可。
- PyPI 源在 `cairn/pyproject.toml` 和根 `Dockerfile` 中固定为阿里云镜像。
- macOS 上的 Docker 由 OrbStack 提供（项目唯一部署方式 Docker Compose 的前置条件）。
- 许可证：GNU AGPLv3（个人/教育用途），商业用途需向上游作者获取单独商业许可（双许可）；贡献代码即同意同时按两种许可授权。

## 仓库结构

```
cairn/                        # Python 项目（pyproject.toml、uv.lock）
  src/cairn/
    cli.py                    # click CLI：`cairn serve` / `cairn dispatch`
    server/
      app.py                  # FastAPI 应用装配 + 静态 UI
      db.py                   # SQLite schema + 连接辅助（DEFAULT_DB 路径）
      models.py               # pydantic 协议模型（Project/Fact/Intent/Hint/Attachment/Settings）
      services.py             # 路由背后的业务逻辑
      routers/                # settings、projects、hints、intents、attachments、export
      static/                 # Web UI（index.html，简体中文 + vendor/ 下的第三方 JS）
    dispatcher/
      config.py               # dispatch.yaml schema、严格校验、prompt 占位符检查、
                              # MOCK_* 行为分布校验
      models.py, contracts.py, output_parser.py, prompting.py, logging.py
      protocol/client.py      # Cairn Server API 的 HTTP 客户端
      scheduler/loop.py       # 主调度循环（DispatcherLoop）
      scheduler/worker_select.py
      tasks/                  # bootstrap.py、reason.py、explore.py、common.py
      runtime/                # 执行后端：containers.py（Docker）、process.py、
                              # backend.py（接口）、heartbeat.py、cancellation.py、
                              # startup_healthcheck.py
      workers/                # base.py（driver ABC）、registry.py、health.py
        adapters/             # claudecode.py、codex.py、pi.py、mock.py
      prompts/{default,mock}/ # markdown prompt 模板（打包资源；各含 bootstrap.md、
                              # bootstrap_conclude.md、reason.md、explore.md、
                              # explore_conclude.md）
  tests/                      # pytest 测试套件，conftest.py 提供 fake
container/                    # worker 镜像：Dockerfile（Kali + 工具 + Agent CLI）、
                              # AGENTS.md + .agents/skills/（烤进镜像的环境简报）
docs/specs/                   # 权威设计文档（中文）：
                              #   server-protocol.md   —— Cairn 协作协议
                              #   dispatcher-design.md —— Dispatcher 行为、任务模型、配置
docs/development-guide.md     # 二次开发指南（中文）
dispatch.example.yaml         # 配置模板（容器执行）
dispatch_mock.yaml            # mock driver 配置，用于离线端到端运行
Dockerfile, docker-compose.yaml  # 应用镜像 + 双服务部署（项目唯一部署方式）
build.sh                      # 一键构建启动脚本：环境检查（自动 brew 安装缺失的
                              # git/uv/OrbStack 并拉起 OrbStack）；探测构建状态 ——
                              # 未构建则走完整流程（uv sync、arm64 worker 镜像、
                              # dispatch.yaml 初始化、pytest、探测多个 GHCR 镜像源
                              # 自动选择可用源构建 cairn-app），已构建则直接用本地
                              # 镜像启动；启动失败时询问是否重新构建
cairn.sh                      # 管理脚本（compose 封装）：start/stop/restart/status/logs，
                              # macOS 上自动拉起 OrbStack/Docker，stop 时清理残留
                              # worker 容器
```

## 构建、运行与测试命令

所有 Python 命令都使用 uv 并加 `--project cairn`：

```bash
# 运行完整测试套件（无需 Docker 或 LLM 端点；83 个测试，约 1 秒）
uv run --project cairn --group dev pytest

# 启动服务器（默认 127.0.0.1:8000；开发调试用，正式部署走 compose）
uv run --project cairn cairn serve

# 运行 Dispatcher（需要 dispatch.yaml；先从 example 复制一份）
uv run --project cairn cairn dispatch --config dispatch.yaml

# 单次运行变体
uv run --project cairn cairn dispatch --config dispatch.yaml --once
uv run --project cairn cairn dispatch --config dispatch.yaml --startup-healthcheck-only

# 一键构建启动：探测构建状态，未构建则完整构建（环境检查、依赖、worker 镜像、
# 配置初始化、测试、应用镜像多镜像源构建），已构建则直接用本地镜像启动
./build.sh                # 加 --force-build 可强制重建 worker 镜像

# 管理服务（compose 封装）
./cairn.sh start|stop|restart|status|logs
```

worker 镜像：本 fork 只在本地构建 arm64 版本（约 20GB，首次构建很慢），Kali 基础镜像走 daocloud 镜像站：

```bash
docker build --platform=linux/arm64 \
  --build-arg KALI_BASE=docker.m.daocloud.io/kalilinux/kali-rolling:latest \
  -t ghcr.io/oritera/cairn-worker-container:latest container/
```

本 fork 不要拉取上游 GHCR worker 镜像 —— 它仅有 amd64。

部署（项目的唯一启动方式）：`docker compose up --build` 启动 `cairn-server`（端口 8000，数据持久化到 `./datas/cairn/`）和 `cairn-dispatcher`（挂载宿主机 Docker socket 和 `./dispatch.yaml`，等待 server 健康检查通过）。应用镜像的基础镜像默认使用南京大学 GHCR 镜像站（`ghcr.nju.edu.cn/astral-sh/uv`，可用 `--build-arg UV_BASE=...` 覆盖）；`build.sh` 会在多个候选镜像源（南大、linkos、上游 ghcr.io）中自动探测并选用第一个连通的源。

## 不可违反的架构规则

以下规则来自 `docs/specs/` —— 将其视为规范；修改行为时必须同步更新这两份规范文档。

- Server 只维护图的一致性。Fact 只可追加；状态变更通过追加新 Fact 表达。
- Dispatcher 是协议的唯一写入方。Agent 只接收渲染好的 prompt 并返回结构化 JSON；它们从不自己认领 intent、发送心跳或调用 API。
- `bootstrap` / `explore` 支持两阶段模式：主执行阶段之后，若超时或解析失败，进入 `conclude` 阶段并复用同一会话（`*_conclude.md` prompt，`conclude_timeout` 预算）。`reason` 是单阶段；任何失败都不写入。
- 认领使用心跳接口：`explore` 在开始前通过 intent 心跳认领；`reason` 认领项目级 `reason` 租约。`runtime.interval` 有意同时作为调度节拍和心跳周期。
- 一个 worker = 一个独立的 LLM 并发配额单位；绝不要把一个 API key 拆给多个 worker。并发上限：`runtime.max_workers`（全局）、`runtime.max_running_projects`（准入）、`runtime.max_project_workers`（每项目）、`workers[].max_running`（每 worker）。Worker 选择遵循 `priority`（升序）和 `task_types`。
- 项目离开 `active` 状态是硬停止：立即取消本地任务、跳过 conclude 兜底，然后清理容器。项目被删除 → 孤儿容器被移除。每个 server 只支持单个 Dispatcher 实例。
- 执行后端只有容器模式：每个项目一个 Docker worker 容器（`runtime.execution` 仅接受 `container`，保留该字段只为对旧配置给出明确的校验错误）。

## 配置

运行时配置是单个 `dispatch.yaml`（见 `dispatch.example.yaml`）。`config.py` 在加载时严格校验：

- 必填的 `runtime.*` / `tasks.*` 字段（间隔、上限、超时；`reason.max_intents` 限制每步新增 intent 数）。
- `container:` 段必填 —— `image`、`network_mode`、`completed_action: stop|remove`、可选 `cap_add`。
- `runtime.worker_healthcheck`：`startup_and_task` | `startup_only`（默认）| `disabled`，配合 `runtime.healthcheck_timeout`。
- Worker 类型：`claudecode`、`codex`、`pi`、`mock`。必需的 LLM 环境变量键（model / base_url / API key）对每个非 mock worker 强制校验。
- `runtime.prompt_group` 从 `dispatcher/prompts/<group>/` 选择 prompt 集；必需文件及其 `{placeholder}` 占位符会被校验。
- `mock` worker 上的 `MOCK_*` 环境变量定义各阶段的延迟范围和结果概率分布（必须总和为 1.0；未知的 `MOCK_*` 键会被拒绝）。
- `common_env` 合并进每个 worker，并被 `worker.env` 覆盖。

## 测试说明

- 框架：pytest，在 `cairn/pyproject.toml` 中配置（`testpaths = ["tests"]`），从仓库根目录用上面的命令运行。已验证：83 个测试通过（约 1 秒），完全离线。
- `tests/conftest.py` 提供 fake（`FakeClient`、`FakeDriver`、`FakeContainerManager`、`FakeLease`）和配置/项目工厂函数。
- `mock` worker driver 加 `prompt_group: mock` 可在无 LLM 的情况下做端到端 Dispatcher 测试（`test_mock_end_to_end.py`，由 `dispatch_mock.yaml` 风格的配置驱动）；`test_server_api.py` 通过 httpx 测试 FastAPI 应用；其余 `test_*.py` 覆盖配置/适配器、契约/driver、数据库迁移、健康检查、协议/启动、运行时逻辑、调度器逻辑、容器归档和 worker 任务。
- 新增行为时，在对应的现有 `test_*.py` 文件中添加测试，并复用 conftest 的 fake。

## 代码风格规范

- 所有 Python 源码、注释、prompt 和配置示例使用英文。README.md、`docs/specs/` 下的设计规范、`docs/` 下的开发指南、`container/AGENTS.md` 中的 worker 环境简报，以及 `build.sh` 和 `cairn.sh` 的用户可见输出为中文 —— 编辑时保持中文。Web UI（`server/static/index.html`）在本 fork 中已本地化为简体中文 —— UI 文本保持中文。
- 模块顶部写 `from __future__ import annotations`；配置和协议数据用 pydantic 模型；日志用 stdlib `logging` 加惰性 `%s` 参数；全量类型标注。
- 注释从简；仅存的少量注释解释非显而易见的设计决策（例如有意的耦合）—— 保持这一惯例。
- 未配置 formatter/linter；与周围代码保持一致（4 空格缩进、双引号字符串）。

## 安全注意事项

- **授权范围**：Cairn 是进攻性安全工具。仅对获得明确授权的系统使用（见 README 免责声明）。
- Worker 容器以危险标志运行 Agent CLI（`--dangerously-skip-permissions`、`--dangerously-bypass-approvals-and-sandbox`），并可通过 `container.cap_add` 请求 Linux 能力（如 `NET_RAW`、`NET_ADMIN`）；Dispatcher 挂载宿主机 Docker socket。
- `dispatch.yaml` 包含 LLM API key 和 token；它由用户提供（仓库只提交 `*.example.yaml` 模板）。绝不要提交填好的 `dispatch.yaml` 或真实凭据。
- Server 没有认证；请相应地进行绑定/暴露（compose 映射端口 8000）。
