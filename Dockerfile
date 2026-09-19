# Base image defaults to the Nanjing University GHCR mirror (China-friendly).
# Use upstream with: docker build --build-arg UV_BASE=ghcr.io/astral-sh/uv:python3.13-trixie
ARG UV_BASE=ghcr.nju.edu.cn/astral-sh/uv:python3.13-trixie
FROM ${UV_BASE}

COPY ./cairn/pyproject.toml /cairn/pyproject.toml
COPY ./cairn/uv.lock /cairn/uv.lock
WORKDIR /cairn
RUN uv sync --frozen --no-install-project -i https://mirrors.aliyun.com/pypi/simple/

COPY ./cairn /cairn
RUN uv sync --frozen -i https://mirrors.aliyun.com/pypi/simple/

ENV TZ=Asia/Shanghai