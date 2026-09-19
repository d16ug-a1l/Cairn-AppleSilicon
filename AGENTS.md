# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project overview

Cairn is a general-purpose problem-solving engine (validated on AI penetration testing / CTF). It models goal-directed exploration as a directed fact-intent graph on a blackboard: **Facts** (confirmed findings, nodes), **Intents** (declared explorations, edges), and **Hints** (external human/agent input, outside the graph). Agents coordinate only through the shared graph (stigmergy); each runs an OODA loop.

The repo has two deliverables:

- **`cairn/`** — the Python application (package `cairn`, version 0.2.1), containing:
  - **Cairn Server** (`src/cairn/server/`) — FastAPI + SQLite truth source. Maintains graph consistency only; does no reasoning. Serves the protocol API and a static web UI (Cytoscape-based graph view in `server/static/`).
  - **Cairn Dispatcher** (`src/cairn/dispatcher/`) — client executor: reads the graph, schedules tasks, manages per-project worker containers (or local processes), and is the **sole protocol writer**. Agents never call the Cairn API directly.
- **`container/`** — the worker container image (Kali Linux + pentest tooling + pinned `claude` / `codex` / `pi` agent CLIs + Playwright), built separately and published as `ghcr.io/oritera/cairn-worker-container:latest`. The Dockerfile's mirror/proxy build args (`KALI_MIRROR`, `PIP_INDEX_URL`, `GH_PROXY`, `NPM_REGISTRY`, `PLAYWRIGHT_DOWNLOAD_HOST`) default to China mirrors (Aliyun, npmmirror, gh-proxy.com) — pass empty values to build against upstream; multi-arch (`TARGETARCH`) builds are supported.

Three task types, all run by the same worker mechanism: `bootstrap` (direct solve attempt at project start), `reason` (read full graph, decide complete / new intents / no-op), `explore` (claim one intent, execute, report one fact).

## Technology stack

- Python ≥ 3.12, managed with **uv** (`uv_build` backend, `uv.lock` locked).
- Dependencies: FastAPI, uvicorn, click, PyYAML, docker (SDK), requests; pydantic is used for config/models. Dev group: pytest, httpx.
- Storage: plain SQLite (`server/db.py`), WAL mode, schema created idempotently on startup; default DB at `~/.local/share/cairn/cairn.db` (override with `cairn serve --db-path`).
- No linter/formatter config (no ruff/black/mypy); no CI config — just keep code consistent with existing style.
- PyPI index is pinned to the Aliyun mirror in `cairn/pyproject.toml` and the root `Dockerfile`.
- License: GNU AGPLv3 for personal/educational use, with a separate commercial license (dual licensing); contributions are accepted under both.

## Repository layout

```
cairn/                        # Python project (pyproject.toml, uv.lock)
  src/cairn/
    cli.py                    # click CLI: `cairn serve` / `cairn dispatch`
    server/
      app.py                  # FastAPI app assembly + static UI
      db.py                   # SQLite schema + connection helper (DEFAULT_DB path)
      models.py               # pydantic protocol models (Project/Fact/Intent/Hint/Settings)
      services.py             # business logic behind the routers
      routers/                # settings, projects, hints, intents, export
      static/                 # web UI (index.html + vendored JS: cytoscape, alpine, tailwind)
    dispatcher/
      config.py               # dispatch.yaml schema, strict validation, prompt token checks,
                              # MOCK_* behavior distributions
      models.py, contracts.py, output_parser.py, prompting.py, logging.py
      protocol/client.py      # HTTP client for the Cairn Server API
      scheduler/loop.py       # main scheduling loop (DispatcherLoop)
      scheduler/worker_select.py
      tasks/                  # bootstrap.py, reason.py, explore.py, common.py
      runtime/                # execution backends: containers.py (Docker), local_backend.py,
                              # local_process.py, process.py, backend.py (interface),
                              # heartbeat.py, cancellation.py, startup_healthcheck.py
      workers/                # base.py (driver ABC), registry.py, health.py
        adapters/             # claudecode.py, codex.py, pi.py, mock.py
      prompts/{default,mock}/ # markdown prompt templates (packaged resources)
  tests/                      # pytest suite, fakes in conftest.py
container/                    # worker image: Dockerfile (Kali + tools + agent CLIs),
                              # AGENTS.md + .agents/skills/ baked into the image as the
                              # agent-facing environment briefing (Chinese, CTF-oriented)
docs/specs/                   # authoritative design docs (Chinese):
                              #   server-protocol.md   — the Cairn collaboration protocol
                              #   dispatcher-design.md — dispatcher behavior, task model, config
dispatch.example.yaml         # container-mode config template
dispatch.local.example.yaml   # local-mode config template (no Docker)
dispatch_mock.yaml            # mock-driver config for offline end-to-end runs
Dockerfile, docker-compose.yaml  # app image + two-service deployment
cairn.sh                      # host helper: start/stop/restart/status/logs for server +
                              # dispatcher (auto-starts OrbStack/Docker on macOS, logs and
                              # pids in .run/, cleans up leftover worker containers on stop)
build.sh                      # one-shot project setup: env checks (auto-starts OrbStack),
                              # uv sync, worker image pull via NJU mirror + retag,
                              # dispatch.yaml init from example, pytest verification
```

## Build, run, and test commands

All Python commands use uv with `--project cairn`:

```bash
# Run the full test suite (no Docker or LLM endpoints needed; 98 tests, ~4s)
uv run --project cairn --group dev pytest

# Start the server (defaults: 127.0.0.1:8000)
uv run --project cairn cairn serve

# Run the dispatcher (requires a dispatch.yaml; cp from an example first)
uv run --project cairn cairn dispatch --config dispatch.yaml

# One-shot variants
uv run --project cairn cairn dispatch --config dispatch.yaml --once
uv run --project cairn cairn dispatch --config dispatch.yaml --startup-healthcheck-only

# Host convenience script (macOS/Linux): manage server + dispatcher together
./cairn.sh start|stop|restart|status|logs

# One-shot project setup (deps, worker image, config init, tests)
./build.sh
```

Deployment: `docker compose up --build` starts `cairn-server` (port 8000, data persisted to `./datas/cairn/`) and `cairn-dispatcher` (mounts the host Docker socket and `./dispatch.yaml`, waits for the server healthcheck). The app image's base defaults to the NJU GHCR mirror (override with `--build-arg UV_BASE=...`). The worker image must be pulled separately (NJU mirror + retag to the canonical name): `docker pull --platform=linux/amd64 ghcr.nju.edu.cn/oritera/cairn-worker-container:latest && docker tag ghcr.nju.edu.cn/oritera/cairn-worker-container:latest ghcr.io/oritera/cairn-worker-container:latest`. The worker image itself is built from `container/` (`docker build . -t cairn-worker-container`).

## Architecture rules you must not break

These come from `docs/specs/` — treat them as the spec; when changing behavior, update the specs to match.

- The Server maintains graph consistency only. Facts are append-only; state changes are expressed by appending new Facts.
- The Dispatcher is the only protocol writer. Agents receive a rendered prompt and return structured JSON; they never claim intents, heartbeat, or call the API themselves.
- `bootstrap` / `explore` support a two-phase mode: main execution, then on timeout/parse-failure a `conclude` phase resuming the same session (`*_conclude.md` prompts, `conclude_timeout` budget). `reason` is single-phase; on any failure it writes nothing.
- Claims use the heartbeat endpoints: `explore` claims via intent heartbeat before starting; `reason` claims the project-level `reason` lease. `runtime.interval` is deliberately both the scheduler tick and the heartbeat cadence.
- One worker = one independent LLM concurrency quota unit; never split one API key across multiple workers. Concurrency caps: `runtime.max_workers` (global), `runtime.max_running_projects` (admission), `runtime.max_project_workers` (per project), `workers[].max_running` (per worker). Worker selection respects `priority` (ascending) and `task_types`.
- Project leaving `active` is a hard stop: cancel local tasks immediately, skip conclude fallback, then clean up the container. Deleted projects → orphan containers are removed. Only a single Dispatcher instance per server is supported.
- `runtime.execution: container` (default, per-project Docker containers) or `local` (workers run as host subprocesses reusing the host's logged-in CLIs; no API keys in config; no sandbox).

## Configuration

Runtime config is a single `dispatch.yaml` (see `dispatch.example.yaml`). `config.py` validates it strictly at load:

- Required `runtime.*` / `tasks.*` fields (intervals, caps, timeouts; `reason.max_intents` caps new intents per step).
- `runtime.execution`: `container` (requires the `container:` section — `image`, `network_mode`, `completed_action: stop|remove`, optional `cap_add`) or `local` (optional `local:` section — `workspace_root`, `completed_action: keep|remove`; each project gets `<workspace_root>/<project_id>/`).
- `runtime.worker_healthcheck`: `startup_and_task` | `startup_only` (default) | `disabled`, with `runtime.healthcheck_timeout`. In local mode, startup instead verifies each worker CLI is installed and on PATH.
- Worker types: `claudecode`, `codex`, `pi`, `mock`. Required LLM env keys (model / base_url / API key) are enforced per execution mode.
- `runtime.prompt_group` selects a prompt set from `dispatcher/prompts/<group>/`; required files and their `{placeholder}` tokens are validated.
- `MOCK_*` env vars on `mock` workers define per-phase delay ranges and outcome probability distributions (must sum to 1.0; unknown `MOCK_*` keys are rejected).
- `common_env` merges into every worker and is overridden by `worker.env`. In local mode, workers also inherit the dispatcher's own environment.

## Testing instructions

- Framework: pytest, configured in `cairn/pyproject.toml` (`testpaths = ["tests"]`), run from repo root with the command above. Verified: 98 tests passing (~4s), fully offline.
- `tests/conftest.py` provides fakes (`FakeClient`, `FakeDriver`, `FakeContainerManager`, `FakeLease`) and config/project factories.
- The `mock` worker driver plus `prompt_group: mock` enable end-to-end dispatcher tests without LLMs (`test_mock_end_to_end.py`, driven by `dispatch_mock.yaml`-style configs); `test_server_api.py` exercises the FastAPI app via httpx; other `test_*.py` files cover config/adapters, contracts/drivers, DB migrations, healthchecks, local execution, protocol/startup, runtime logic, scheduler logic, and worker tasks.
- When adding behavior, add tests in the matching existing `test_*.py` file and reuse the conftest fakes.

## Code style guidelines

- English for all Python source, comments, and prompts. README.md, the design specs under `docs/specs/`, the development guide under `docs/`, the worker-environment briefing in `container/AGENTS.md`, and the user-facing output of `cairn.sh` are in Chinese — keep them in Chinese when editing.
- `from __future__ import annotations` at the top of modules; pydantic models for config and protocol data; stdlib `logging` with lazy `%s` args; type hints throughout.
- Minimal comments; the few that exist explain non-obvious design decisions (e.g. intentional couplings) — preserve that convention.
- No formatter/linter is configured; match surrounding code (4-space indent, double-quoted strings).

## Security considerations

- **Authorization scope**: Cairn is an offensive-security tool. Use it only against systems you are explicitly authorized to test (see the README disclaimer).
- Worker containers run agent CLIs with dangerous flags (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`) and may request Linux capabilities via `container.cap_add` (e.g. `NET_RAW`, `NET_ADMIN`); the dispatcher mounts the host Docker socket. Local mode runs agents with the host user's permissions and no sandbox — run the dispatcher on the host, never via docker-compose, in local mode.
- `dispatch.yaml` contains LLM API keys and tokens; it is user-supplied (only `*.example.yaml` templates are committed). Never commit a filled-in `dispatch.yaml` or real credentials.
- The server has no authentication; bind/expose it accordingly (compose maps port 8000).
