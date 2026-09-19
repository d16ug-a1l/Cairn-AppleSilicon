ARG KALI_BASE=kalilinux/kali-rolling:latest
FROM ${KALI_BASE}

ARG TARGETARCH
# Optional apt mirror override, e.g. http://mirrors.tuna.tsinghua.edu.cn/kali
ARG KALI_MIRROR=
# Optional pip index override, e.g. https://pypi.tuna.tsinghua.edu.cn/simple
ARG PIP_INDEX_URL=
# Optional GitHub proxy prefix for release downloads and git clones,
# e.g. https://gh-proxy.com/
ARG GH_PROXY=
# Optional npm registry override, e.g. https://registry.npmmirror.com
ARG NPM_REGISTRY=
RUN if [ -n "${KALI_MIRROR}" ]; then \
        sed -i "s|http://http.kali.org/kali|${KALI_MIRROR}|g" \
            /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true; \
    fi && \
    if [ -n "${PIP_INDEX_URL}" ]; then \
        printf '[global]\nindex-url = %s\n' "${PIP_INDEX_URL}" > /etc/pip.conf; \
    fi && \
    printf '%s\n' \
        'Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled "false";' \
        'Acquire::Retries "5";' \
        > /etc/apt/apt.conf.d/99build-tuning

RUN apt update && \
    apt -y install kali-linux-headless && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash kali && \
    echo "kali ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    if [ -n "${GH_PROXY}" ]; then \
        git config --system url."${GH_PROXY}https://github.com/".insteadOf "https://github.com/"; \
    fi
USER kali

RUN sudo apt update && \
    sudo apt install -y bsdextrautils npm jq iputils-ping sshpass ncat rlwrap \
    bloodyad coercer enum4linux-ng pwncat chisel-common-binaries \
    dirsearch yq krb5-user gitleaks naabu nikto netexec adb && \
    if [ "$TARGETARCH" != "amd64" ]; then \
        sudo apt install -y cmake build-essential python3-dev python3-pwntools python3-pymongo; \
    fi && \
    sudo apt clean && \
    sudo rm -rf /var/lib/apt/lists/* && \
    if [ "$TARGETARCH" = "amd64" ]; then \
        pip3 install pwntools pymongo --break-system-packages; \
    fi && \
    if [ -n "${NPM_REGISTRY}" ]; then \
        sudo npm config set registry "${NPM_REGISTRY}" --global; \
    fi && \
    sudo npm install -g @playwright/cli@latest && \
    cd /tmp && \
    if [ "$TARGETARCH" = "amd64" ]; then \
        playwright-cli install; \
    else \
        playwright-cli install || \
        echo "WARNING: playwright browser install failed on ${TARGETARCH}; run 'playwright-cli install' at runtime if needed"; \
    fi

RUN cd /tmp && \
    wget -q "${GH_PROXY}https://github.com/projectdiscovery/katana/releases/download/v1.5.0/katana_1.5.0_linux_${TARGETARCH}.zip" -O katana.zip && \
    wget -q "${GH_PROXY}https://github.com/projectdiscovery/nuclei/releases/download/v3.7.1/nuclei_3.7.1_linux_${TARGETARCH}.zip" -O nuclei.zip && \
    wget -q "${GH_PROXY}https://github.com/hahwul/dalfox/releases/download/v2.12.0/dalfox-linux-${TARGETARCH}.tar.gz" -O dalfox.tar.gz && \
    wget -q "${GH_PROXY}https://github.com/BishopFox/cloudfox/releases/download/v2.0.1/cloudfox-linux-${TARGETARCH}.zip" -O cloudfox.zip && \
    git clone --depth 1 "https://github.com/projectdiscovery/nuclei-templates.git" /home/kali/.local/nuclei-templates && \
    unzip -q katana.zip katana && sudo mv katana /usr/local/bin/ && \
    unzip -q nuclei.zip nuclei && sudo mv nuclei /usr/local/bin/ && \
    tar -xzf dalfox.tar.gz && sudo mv dalfox-linux-${TARGETARCH} /usr/local/bin/dalfox && \
    unzip -q cloudfox.zip cloudfox/cloudfox && sudo mv cloudfox/cloudfox /usr/local/bin/ && \
    if [ -z "${GH_PROXY}" ]; then nuclei -ut; fi && \
    sudo rm -rf /tmp/*

RUN mkdir -p /home/kali/knowledges && cd /home/kali/knowledges && \
    git clone --depth=1 https://github.com/swisskyrepo/PayloadsAllTheThings.git && \
    git clone --depth=1 https://github.com/swisskyrepo/InternalAllTheThings.git && \
    git clone --depth=1 https://github.com/HackTricks-wiki/hacktricks.git && \
    git clone --depth=1 https://github.com/HackTricks-wiki/hacktricks-cloud.git

RUN mkdir -p /home/kali/tools && cd /home/kali/tools && \
    wget -q "${GH_PROXY}https://github.com/frohoff/ysoserial/releases/download/v0.0.6/ysoserial-all.jar" -O ysoserial.jar && \
    git clone --depth=1 https://github.com/ticarpi/jwt_tool.git && \
    cd jwt_tool && pip3 install -r requirements.txt --break-system-packages && \
    git clone --depth=1 https://github.com/IOActive/jdwp-shellifier.git

RUN mkdir -p /home/kali/pocs && cd /home/kali/pocs && \
    git clone --depth=1 https://github.com/iSee857/CVE-PoC.git && \
    git clone --depth=1 https://github.com/zhzyker/exphub.git && \
    git clone --depth=1 https://github.com/passwa11/2023Hvv_.git && \
    git clone --depth=1 https://github.com/Threekiii/Awesome-POC.git && \
    git clone --depth=1 https://github.com/vulhub/vulhub.git

RUN cd /tmp && \
    wget -q "${GH_PROXY}https://github.com/sharkdp/fd/releases/download/v10.4.2/fd_10.4.2_${TARGETARCH}.deb" -O fd.deb && \
    if [ "$TARGETARCH" = "amd64" ]; then \
        wget -q "${GH_PROXY}https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep_15.1.0-1_amd64.deb" -O ripgrep.deb && \
        sudo apt install ./ripgrep.deb ./fd.deb; \
    else \
        wget -q "${GH_PROXY}https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-aarch64-unknown-linux-gnu.tar.gz" -O ripgrep.tar.gz && \
        tar -xzf ripgrep.tar.gz && \
        sudo cp ripgrep-15.1.0-aarch64-unknown-linux-gnu/rg /usr/local/bin/ && \
        sudo apt install ./fd.deb; \
    fi && \
    sudo rm -rf /tmp/* && \
    sudo apt clean && \
    sudo rm -rf /var/lib/apt/lists/*
    
RUN pip3 install tccli awscli --break-system-packages && \
    sudo bash -c "$(curl -fsSL https://aliyuncli.alicdn.com/install.sh)"

RUN sudo npm install -g @openai/codex@0.118.0
RUN sudo npm install -g @anthropic-ai/claude-code@2.1.98
RUN sudo npm install -g @mariozechner/pi-coding-agent@0.73.0

RUN mkdir -p /home/kali/.config/nuclei && \
    echo >> /home/kali/.config/nuclei/config.yaml && \
    echo "disable-update-check: true" >> /home/kali/.config/nuclei/config.yaml && \
    echo "update-template-dir: /home/kali/.local/nuclei-templates" >> /home/kali/.config/nuclei/config.yaml && \
    rm -rf /home/kali/nuclei-templates
RUN sudo rm -rf /usr/lib/llvm-*/build && \
    sudo chmod o+rx /usr/lib/mysql/plugin/auth_pam_tool_dir /etc/ssl/private
RUN printf '%s\n' 'PS1="${PS1%\\n*} \[\033[0;36m\]\D{%y-%m-%d} - \t\[\033[;32m\]\n${PS1##*\\n}"' >> /home/kali/.bashrc && \
    mkdir -p /home/kali/workspace && cd /home/kali/workspace && git init
ENV TZ=Asia/Shanghai
ENV PLAYWRIGHT_MCP_BROWSER=chromium
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV PYTHONUNBUFFERED=1

COPY ./.agents /home/kali/workspace/.agents
COPY ./.agents /home/kali/workspace/.claude
COPY ./AGENTS.md /home/kali/workspace/AGENTS.md
COPY ./AGENTS.md /home/kali/workspace/CLAUDE.md

WORKDIR /home/kali/workspace