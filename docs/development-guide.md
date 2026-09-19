# Cairn 二次开发指南

本文档面向希望阅读源码并进行二次开发的开发者，按"概念 → 架构 → Server → Dispatcher → Web UI → 测试 → 常见开发任务"的顺序展开，并附关键 `文件:行号` 引用。

> 权威设计规范在 `docs/specs/`（中文）：`server-protocol.md`（协作协议）与 `dispatcher-design.md`（调度器设计）。**修改行为时必须同步更新这两份规范**。仓库级约定见根目录 `AGENTS.md`。

---

## 1. 核心概念

Cairn 把"目标导向的探索"建模为一张有向**事实-意图图**，落在黑板（blackboard）上：

- **Fact（事实）**：已确认的发现，图中的节点。**只增不改（append-only）**，状态变化通过追加新 Fact 表达。
- **Intent（意图）**：已声明的探索，图中的边（从一个或多个 Fact 指向一个待产出的 Fact）。
- **Hint（提示）**：外部人类/Agent 的旁注，**不属于图**，任何项目状态下都可写入。

协调机制是**趋化性（stigmergy）**：多个 Agent 不直接通信，只通过读写共享图间接协调；每个 Agent 独立运行 OODA 循环（观察-判断-决策-行动）。

两个角色严格分离：

| 组件 | 职责 | 不做的事 |
|---|---|---|
| **Cairn Server**（FastAPI + SQLite） | 维护图的一致性，是唯一的真相源 | 不做任何推理 |
| **Cairn Dispatcher** | 读图、调度任务、管理 worker，**唯一的协议写入方** | 不直接被 Agent 调用 |

三类任务（由同一套 worker 机制执行）：

- `bootstrap`（起步）：项目开始时直接尝试解题
- `reason`（推理）：读全图，决定"完成 / 声明新意图 / 空操作"
- `explore`（探索）：认领一条意图，执行，报告一条事实

---

## 2. 仓库布局与技术栈

```
cairn/                        # Python 项目（uv 管理，包名 cairn）
  src/cairn/
    cli.py                    # click CLI：cairn serve / cairn dispatch
    server/                   # FastAPI + SQLite 真相源
    dispatcher/               # 调度器：唯一的协议写入方
  tests/                      # pytest，全离线，fakes 在 conftest.py
container/                    # worker 容器镜像（Kali + 渗透工具 + agent CLI）
docs/specs/                   # 权威中文设计文档
dispatch.example.yaml         # 容器模式配置模板
dispatch.local.example.yaml   # 本地模式配置模板（无 Docker）
dispatch_mock.yaml            # mock 驱动离线端到端配置
cairn.sh                      # 宿主机管理脚本（start/stop/restart/status/logs）
```

技术栈：Python ≥ 3.12 + uv；FastAPI、uvicorn、click、PyYAML、docker SDK、requests、pydantic；存储为纯 SQLite（WAL 模式）。**无 linter/formatter、无 CI**，保持与现有代码风格一致（4 空格缩进、双引号、`from __future__ import annotations`、stdlib logging 惰性 `%s` 参数）。

常用命令：

```bash
uv run --project cairn --group dev pytest          # 全部测试（~98 个，约 4 秒，全离线）
uv run --project cairn cairn serve                 # 启动服务器（127.0.0.1:8000）
uv run --project cairn cairn dispatch --config dispatch.yaml        # 启动调度器
uv run --project cairn cairn dispatch --config dispatch_mock.yaml   # mock 离线端到端
./cairn.sh start|stop|restart|status|logs                            # 宿主机一体管理
```

---

## 3. Cairn Server

代码：`cairn/src/cairn/server/`。设计极简：**无 ORM、无鉴权、单文件 SQLite、同步路由函数**。

### 3.1 数据模型（`server/models.py`）

| 模型 | 关键字段 | 位置 |
|---|---|---|
| `Fact` | `id`、`description` | models.py:13 |
| `Intent` | `id`、`from_`（别名 `from`，多源）、`to`、`description`、`creator`、`worker`、`last_heartbeat_at`、`created_at`、`concluded_at` | models.py:18 |
| `Hint` | `id`、`content`、`creator`、`created_at` | models.py:32 |
| `ProjectMeta` | `id`、`title`、`status`（`active/stopped/completed`）、`bootstrap_enabled`、`reason`（租约） | models.py:46 |
| `ProjectDetail` | project + facts + intents + hints | models.py:63 |
| `Settings` | `intent_timeout`、`reason_timeout`（秒，≥5） | models.py:8 |

请求模型均带 strip + 非空校验（`CreateProjectRequest` models.py:83、`CreateIntentRequest` models.py:112 等）。注意 `UpdateProjectStatusRequest` **只允许** `active/stopped`（models.py:212）——`completed` 只能走 `POST .../complete`。

### 3.2 SQLite 表结构（`server/db.py`）

schema 幂等创建（db.py:12-82），无显式索引，全靠主键：

- `projects`：含 reason 租约四列（`reason_worker/reason_trigger/reason_started_at/reason_last_heartbeat_at`）
- `facts`：复合主键 `(id, project_id)`，外键 `ON DELETE CASCADE`；**没有 created_at / worker 列**——append-only 语义的直接体现
- `intents` + `intent_sources`（多源边关联表）；`hints`；`counters` / `scoped_counters`（ID 生成）
- `settings`：单行表，超时默认 15 秒

连接管理：`db.configure()` 只生效一次（db.py:85），含旧库列迁移 `_ensure_project_columns`（db.py:96）；`get_conn()` 上下文管理器每请求新建连接、WAL、外键开启、正常 commit / 异常 rollback（db.py:106）。

### 3.3 API 端点全集

| 方法 + 路径 | 用途 | 位置 |
|---|---|---|
| `GET/PUT /settings` | 读写超时配置 | routers/settings.py |
| `GET /projects` | 项目列表（含计数，先做惰性超时清理） | routers/projects.py:44 |
| `POST /projects` | 创建项目，自动插入 origin/goal 两条特殊 Fact | projects.py:77 |
| `GET /projects/{id}` | 项目全量详情 | projects.py:124 |
| `DELETE /projects/{id}` | 删除（CASCADE 清子表） | projects.py:147 |
| `PUT /projects/{id}/title` | 重命名（任何状态允许） | projects.py:154 |
| `PUT /projects/{id}/status` | active ↔ stopped；切 stopped 时清空所有 claim 和 reason 租约 | projects.py:166 |
| `POST /projects/{id}/reason/claim\|heartbeat\|release` | reason 租约三件套 | projects.py:191 |
| `POST /projects/{id}/complete` | 插入指向 goal 的已结论 Intent，项目置 completed | projects.py:257 |
| `POST /projects/{id}/reopen` | 删除完成 Intent + 追加新 Fact，回到 active | projects.py:303 |
| `POST /projects/{id}/intents` | 声明意图（worker 非空即创建即认领） | routers/intents.py:28 |
| `POST .../intents/{iid}/heartbeat\|release\|conclude` | 认领/续租、释放、收尾（原子写 Fact + 落定 Intent） | intents.py:74/96/118 |
| `POST /projects/{id}/hints` | 添加提示（任何状态可写） | routers/hints.py:10 |
| `GET /projects/{id}/export?format=yaml\|timeline` | 导出（协调状态不导出） | routers/export.py:154 |

### 3.4 关键机制

**惰性过期（lazy expiry）**：没有后台定时器。每次相关读写前调用 `expire_workers()` / `expire_reason_leases()`（services.py:222/240），用 SQLite `julianday` 差值判断心跳超时，把占用字段置 NULL。认领仲裁在 `get_claimable_open_intent_or_404`（services.py:112）：已结论 409、被他人占用未超时 409。

**项目状态机**：`active ↔ stopped`（PUT status）；`active → completed`（仅 POST complete）；`completed → active`（仅 POST reopen）。写操作门禁：探索类写（intent/reason/complete）要求 `active`；hint 任何状态可写；title 不限状态。

**append-only 的体现**：代码中不存在对 facts 表的 UPDATE/DELETE（除项目删除 CASCADE）。reopen 也是删 Intent + 追加新 Fact，从不改 Fact。

**新增端点的既有模式**：同步 `def` + `with get_conn() as conn` + 先跑 `expire_*` 惰性清理 + 调 services.py 的门禁函数（`get_project_or_404`、`check_project_active` 等，services.py:51-97）。

---

## 4. Cairn Dispatcher

代码：`cairn/src/cairn/dispatcher/`（下文省略该前缀）。

### 4.1 调度主循环（`scheduler/loop.py`）

`DispatcherLoop.run`（loop.py:80）每轮顺序：

1. **首轮**：启动健康检查；校验 server 的 `intent_timeout`/`reason_timeout` 必须大于 `runtime.interval`，否则拒绝启动（loop.py:906）
2. **收割**已完成任务（`_reap_futures`，loop.py:720）：outcome 为 `unhealthy` → worker 冷却 5s；`rejected` → (项目, 任务类型, worker) 三元组冷却 5s；reason 成功 → 更新 `ReasonCheckpoint`
3. **拉项目列表** → 刷新在跑集合 → **硬停止：取消所有非 active 项目的在跑任务**（`_cancel_inactive_tasks`，loop.py:845）→ 排队容器清理
4. **分派**（`_dispatch_available`，loop.py:191），随后 `sleep(runtime.interval)`

**`runtime.interval` 的双重身份**：既是调度 tick，也是心跳节奏（三类任务都以它构造 `HeartbeatLease`）。心跳线程 403/409 立即判定租约丢失并 kill 进程，瞬时错误容忍 `2×interval` 宽限（runtime/heartbeat.py:88）。

**并发上限**：`max_workers`（全局，即线程池大小）、`max_running_projects`（项目准入，只限新进入的 idle 项目）、`max_project_workers`（单项目）、`workers[].max_running`（单 worker）。

**Worker 选择**：排除 task_types 不匹配 / busy / 冷却中者后，按 `(priority 升序, 当前运行数, random)` 排序取首（`scheduler/worker_select.py:8`）；项目遍历用游标轮转保证公平。

**分派优先级**（`_try_dispatch_project`，loop.py:254）：initial 项目 → bootstrap（若启用且有支持的 worker）或直接 reason("initial")；非 initial → reason 优先（触发条件：新 fact / 新 hint / open intents 归零）→ 再 explore（取最新创建的未认领 intent）。**claim 在调度线程内完成**（提交线程池前），403/409 视为竞争失败直接放弃。

### 4.2 三类任务（`tasks/`）

公共骨架 `tasks/common.py`：`run_worker_process`（common.py:73，communicate 超时外加 15s 宽限）；`project_allows_conclude_fallback`（common.py:111，项目离开 active 后跳过收尾）；`write_conclude_result*` 写 API。

| | bootstrap | reason | explore |
|---|---|---|---|
| 阶段 | 两阶段（主执行 + conclude 收尾） | **单阶段，任何失败什么都不写** | 两阶段 |
| 租约 | intent heartbeat | 项目级 reason lease | intent heartbeat |
| 成功输出 | fact + complete | complete / intents / noop | fact（conclude 接口） |
| 超时/解析失败 | 同 session 续跑 conclude（预算 `conclude_timeout`），只写 fact 不 complete | 失败即弃 | 同 session 续跑 conclude |

任务返回的 outcome 字符串：`success / failed / cancelled / unhealthy / rejected`，供收割逻辑消费。

### 4.3 输出契约（`contracts.py`、`output_parser.py`）

Agent 只拿到渲染后的 prompt，返回**结构化 JSON**；Agent 自己从不调 API。

- 提取：`extract_json_object`（output_parser.py:11）依次尝试整段解析 → 剥 ```` ```json ```` 围栏 → 逐 `{` 位置 `raw_decode`
- 信封：`{"accepted": true, "data": {...}}` 或 `{"accepted": false, "reason": ...}`（→ outcome `rejected`）；无 `accepted` 键时按形状识别裸 payload（向后兼容）
- reason 的 `data`：`complete={from,description}` 或 `intents=[...]`（互斥，截断到 `max_intents`）；`open_intents` 非空时禁止空 intents/noop
- bootstrap execute 必须同时含 `fact.description` 与 `complete.description`；conclude 阶段只需 `fact.description`；explore 只需 `description`

### 4.4 Worker 驱动层（`workers/`）

ABC 在 `workers/base.py:18`：`check_health` / `build_execute` / `build_conclude` / `extract_session` / `extract_response_text` / `supports_conclude` / `local_binary`。便利基类：`SeedSessionDriver`（自生成 UUID）、`RegexSessionDriver`（从 stderr 正则抓 session）。

注册表 `workers/registry.py`：`DRIVERS`（容器模式）与 `LOCAL_DRIVERS`（本地模式）两张表。

四个适配器（`workers/adapters/`）：

- **claudecode**：`claude --session-id <uuid> --dangerously-skip-permissions -p -- <prompt>`，收尾 `claude -r <session>`
- **codex**：容器模式注入 `model_providers.cairn.*` 配置；session 从 stderr 提取；收尾 `codex exec resume <session>`
- **pi**：写 `models.json` 后 `pi --provider cairn --mode json ...`；输出解析 NDJSON 事件流
- **mock**：内嵌 Python 脚本按 `MOCK_*` 概率产出契约 JSON 或故障，用于离线测试

### 4.5 运行时后端（`runtime/`）

接口 `backend.py:9`（`ExecutionBackend` Protocol）与 `process.py:27`（`ExecProcess`）。

- **container 模式**（`containers.py`）：每项目一个常驻容器 `cairn-dispatch-<project_id>`（`sleep infinity`），`docker exec` 跑任务，coreutils `timeout -k` 包裹命令；`write_text_file` 手工构 tar 走 `put_archive`；清理分 completed/stopped/orphan 三种
- **local 模式**（`local_backend.py` + `local_process.py`）：无容器，每项目工作目录 `<workspace_root>/<project_id>/`；继承宿主编环境 + worker.env；独立进程组，停止顺序 SIGTERM → 宽限 → SIGKILL 整组；复用宿主机已登录的 CLI，**无沙箱**

辅助组件：`heartbeat.py`（租约续期线程 + 失败 kill）、`cancellation.py`（线程安全的取消记录）、`startup_healthcheck.py`（并发检查所有 driver，全部失败才拒绝启动）。

### 4.6 配置（`config.py`）

单一 `dispatch.yaml`，pydantic 严格校验（`extra="forbid"`）：

- `server`、`common_env`（并入每个 worker.env，worker 级覆盖）
- `runtime`：`max_workers / max_running_projects / max_project_workers / interval / healthcheck_timeout`（必填）、`worker_healthcheck`（默认 `startup_only`）、`execution`（默认 `container`）、`prompt_group`
- `tasks`：`bootstrap/explore` 需 `timeout + conclude_timeout`；`reason` 需 `timeout`；`max_intents` 默认 3
- `container` / `local`：按 execution 模式分别强制要求
- `workers[]`：`name`（全局唯一）、`type`、`task_types`、`max_running`、`priority`、`env`；容器模式强制要求各类型对应的 LLM env 键（`WORKER_ENV_KEYS`，config.py:20）
- **prompt token 校验**：default 组每个模板必须含规定占位符（config.py:294）
- **MOCK_\* 校验**：每阶段 `delay` 区间 + `outcomes` 概率分布（Decimal 精确求和 = 1.0）、支持 `rules` 条件强制 outcome、未知 `MOCK_` 键直接拒绝

**Prompt 系统**（`prompting.py`）：`importlib.resources` 读 `prompts/<group>/<name>`，`str.replace` 渲染。模板共 5 个：`bootstrap.md`、`bootstrap_conclude.md`、`reason.md`、`explore.md`、`explore_conclude.md`。占位符：reason 用 `{graph_yaml}/{fact_ids}/{open_intents}/{max_intents}`；explore 用 `{graph_yaml}/{intent_id}/{intent_description}`；bootstrap 用 `{origin}/{goal}/{hints}`。

### 4.7 协议客户端与 CLI

`protocol/client.py` 的 `CairnClient` 封装全部 API；写操作返回不抛异常的 `ApiResult`，连接异常转成 `status_code=0`；每线程一个 `requests.Session`。

`cli.py` 的 `cairn dispatch`：`--config`（必填）、`--once`（跑一轮退出）、`--startup-healthcheck-only`、`--log-level`。

---

## 5. Web UI（`server/static/index.html`）

单文件应用（Alpine.js + Cytoscape + Tailwind，JS 全部 vendored 在 `static/vendor/`，无构建步骤）。界面文案为中文；注意协议枚举值（`active/completed` 等）在 JS 逻辑中保持英文原值，仅显示层映射为中文（如 `projectStatusLabel()`）。改 UI 时直接编辑该文件即可，`GET /` 由 FastAPI 以 FileResponse 伺服（`server/app.py:35`）。

---

## 6. 测试

全部离线，约 98 个用例：`uv run --project cairn --group dev pytest`。

- **fakes**（`tests/conftest.py`）：`make_config` / `make_project` / `make_intent` 工厂；`FakeClient`、`FakeDriver`、`FakeContainerManager`、`FakeLease`。写 dispatcher 测试时通常 monkeypatch `workers.registry.get_driver` 返回 FakeDriver，直接调 `run_*_task`
- **Server**：`test_server_api.py` 用 FastAPI `TestClient` + 临时 SQLite（monkeypatch 重置 `db._db_path`），覆盖全链路工作流、状态门禁、超时回收；`test_db_migrations.py` 验证旧库列迁移
- **Dispatcher**：`test_scheduler_logic.py`（分派/选择/触发）、`test_worker_tasks.py`（三类任务与 conclude fallback）、`test_runtime_logic.py`、`test_config_and_adapters.py`、`test_contracts_and_drivers.py`、`test_healthcheck.py`、`test_local_execution.py`
- **mock 端到端**（`test_mock_end_to_end.py`）：真实 TestClient + 本地进程替换 Docker + `prompt_group: mock` + `MOCK_*` 强制 outcome，覆盖 bootstrap 直接完成、reason→explore 链、健康检查故障转移等

新增行为时：在对应的现有 `test_*.py` 中加用例，复用 conftest 的 fakes。

---

## 7. 常见二次开发任务

**新增一个 worker 类型**（如接入新的 agent CLI）：
1. `config.py:14` 的 `WorkerType` Literal 加类型名；`WORKER_ENV_KEYS`（config.py:20）声明其 env 键
2. `workers/adapters/` 新建驱动（实现 `WorkerDriver` ABC），在 `adapters/__init__.py` 导出
3. `workers/registry.py` 两张表注册（如需区分 local 变体）
4. 如需新 prompt 占位符：更新 `DEFAULT_PROMPT_REQUIRED_TOKENS` 与 prompts 模板
5. 测试加在 `test_config_and_adapters.py` / `test_contracts_and_drivers.py` / `test_healthcheck.py`

**新增一套 prompt 组**：在 `dispatcher/prompts/<group>/` 放 5 个模板文件，确保含规定占位符（mock 组不要求 `graph_yaml`），配置 `runtime.prompt_group: <group>`。

**新增 API 端点**：遵循 3.4 节的既有模式（同步 def + `get_conn()` + `expire_*` + 门禁函数），同步更新 `docs/specs/server-protocol.md` 与 `test_server_api.py`。

**修改协议/调度行为**：先读 `docs/specs/` 两份规范，改代码的同时更新规范。

---

## 8. 架构红线（不可打破）

1. Server 只维护图一致性；Fact append-only
2. Dispatcher 是唯一协议写入方；Agent 只返回结构化 JSON，从不直接调 API
3. bootstrap/explore 两阶段（conclude 续跑同 session）；reason 单阶段，失败不写
4. `runtime.interval` 同时是调度 tick 和心跳节奏；server 超时必须大于它
5. 一个 worker = 一个独立 LLM 并发配额；不要把一个 API key 拆给多个 worker
6. 项目离开 active 即硬停止：立即取消任务、跳过 conclude fallback、清理容器
7. 单服务器只支持单 Dispatcher 实例

---

## 9. 安全须知

Cairn 是攻击性安全工具，**仅用于获得明确授权的测试目标**。worker 容器内 agent CLI 以危险免确认标志运行，dispatcher 挂载宿主机 Docker socket；local 模式以宿主机用户权限无沙箱运行。`dispatch.yaml` 含 API key，切勿提交。Server 无鉴权，注意绑定与暴露范围。
