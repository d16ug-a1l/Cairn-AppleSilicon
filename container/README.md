```
docker build . -t cairn-worker-container
```

Mirror build args (`KALI_MIRROR`, `PIP_INDEX_URL`, `GH_PROXY`, `NPM_REGISTRY`, `PLAYWRIGHT_DOWNLOAD_HOST`) default to China mirrors; pass empty values to build against upstream sources, e.g.:

```
docker build . -t cairn-worker-container --build-arg KALI_MIRROR= --build-arg GH_PROXY=
```
