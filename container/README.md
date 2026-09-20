This fork builds the worker image for arm64 only (the upstream GHCR publish is amd64-only):

```
docker build --platform=linux/arm64 \
  --build-arg KALI_BASE=docker.m.daocloud.io/kalilinux/kali-rolling:latest \
  -t ghcr.io/oritera/cairn-worker-container:latest .
```

Mirror build args (`KALI_MIRROR`, `PIP_INDEX_URL`, `GH_PROXY`, `NPM_REGISTRY`) default to China mirrors; pass empty values to build against upstream sources, e.g.:

```
docker build --platform=linux/arm64 -t cairn-worker-container --build-arg KALI_MIRROR= --build-arg GH_PROXY= .
```
