# syntax=docker/dockerfile:1.7
# agentic-dev-base. Build from the repository root (agentic build-base does this):
#   docker build -f image/Dockerfile -t agentic-dev-base:local .

# Optional build context "agentic-ca": CA certificates for building behind a TLS-intercepting
# proxy. Empty by default; agentic build-base passes ~/.agentic/ca when it exists. The
# certificates come from the developer's machine, never from this repository.
FROM scratch AS agentic-ca

FROM ubuntu:24.04
ARG YQ_VERSION=v4.44.3
ARG NODE_HARNESS=22
ARG JAVA_BASE=21
ARG MAVEN_BASE=3.9.9
ARG PYTHON_BASE=3.12
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    AGENTIC_DIR=/opt/agentic \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    AWS_PAGER="" \
    DISABLE_AUTOUPDATER=1 \
    JAVA_HOME=/opt/java/${JAVA_BASE} \
    MAVEN_HOME=/opt/maven/${MAVEN_BASE} \
    PATH=/usr/local/sbin:/usr/local/bin:/opt/java/${JAVA_BASE}/bin:/opt/maven/${MAVEN_BASE}/bin:/opt/node/${NODE_HARNESS}/bin:/usr/sbin:/usr/bin:/sbin:/bin

# CA certificates first, so every later download works behind a TLS-intercepting proxy
RUN --mount=type=bind,from=agentic-ca,target=/tmp/agentic-ca \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && mkdir -p /usr/local/share/ca-certificates/agentic \
 && (cp /tmp/agentic-ca/*.crt /usr/local/share/ca-certificates/agentic/ 2>/dev/null || true) \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# OS packages
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client bash make build-essential unzip zip tar xz-utils \
      jq ripgrep tmux less procps python3 python3-venv pipx libnss3-tools xvfb lsb-release wl-clipboard \
 && rm -rf /var/lib/apt/lists/*

# gh, Docker CLI, Azure CLI from their vendor repositories
RUN install -d /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" > /etc/apt/sources.list.d/azure-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh docker-ce-cli docker-buildx-plugin docker-compose-plugin azure-cli \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2, yq, uv
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/aws.zip \
 && unzip -q /tmp/aws.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/aws.zip \
 && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)" -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq \
 && curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

# Base tools through the same presets projects use
COPY image/tools /opt/agentic/tools
RUN /opt/agentic/tools/java.sh install ${JAVA_BASE} \
 && /opt/agentic/tools/maven.sh install ${MAVEN_BASE} \
 && /opt/agentic/tools/node.sh install ${NODE_HARNESS} \
 && /opt/agentic/tools/python.sh install ${PYTHON_BASE}

# Harness CLIs and the Playwright MCP, always run on Node ${NODE_HARNESS} whatever node a project prefers
RUN PATH=/opt/node/${NODE_HARNESS}/bin:$PATH npm install -g --prefix /opt/agentic/npm \
      @anthropic-ai/claude-code @github/copilot ccusage @playwright/mcp \
 && for b in /opt/agentic/npm/bin/*; do \
      n="$(basename "$b")"; \
      printf '#!/bin/sh\nPATH=/opt/node/%s/bin:$PATH exec %s "$@"\n' "${NODE_HARNESS}" "$b" > "/usr/local/bin/$n"; \
      chmod 755 "/usr/local/bin/$n"; \
    done \
 && find /opt/agentic/npm/lib/node_modules/ccusage -path '*/bin/ccusage' -type f -exec chmod 755 {} + \
 && ln -s playwright-mcp /usr/local/bin/mcp-server-playwright

# Python MCP servers and Graphify, as uv tools shared by every user
RUN UV_TOOL_DIR=/opt/agentic/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python ${PYTHON_BASE} mcp-atlassian \
 && UV_TOOL_DIR=/opt/agentic/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python ${PYTHON_BASE} 'graphifyy[mcp]' \
 && chmod -R a+rX /opt/agentic/uv-tools /opt/python

# Chromium and its system libraries, for Playwright and the Playwright MCP
RUN mkdir -p /ms-playwright \
 && PATH=/opt/node/${NODE_HARNESS}/bin:$PATH node /opt/agentic/npm/lib/node_modules/@playwright/mcp/node_modules/playwright/cli.js install --with-deps chromium \
 && rm -rf /var/lib/apt/lists/*

# User dev, mount points and the container marker
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && groupadd -g 1000 dev && useradd -m -u 1000 -g 1000 -s /bin/bash dev \
 && mkdir -p /etc/agentic /work /workspaces /agentic-config /opt/agentic/claude-plugins /opt/agentic/defaults \
 && printf 'agentic\n' > /etc/agentic/container \
 && chown -R dev:dev /work /workspaces /opt/agentic/claude-plugins /ms-playwright

# The agentic layer (changes most often, so it comes last)
COPY image/lib /opt/agentic/lib
COPY image/start.d /opt/agentic/start.d
COPY image/worker.d /opt/agentic/worker.d
COPY image/bin /opt/agentic/bin
COPY image/task /opt/agentic/task
COPY image/hooks.d /opt/agentic/hooks.d
COPY derive /opt/agentic/derive
COPY config /opt/agentic/config
COPY schema /opt/agentic/schema
COPY skills /opt/agentic/skills
COPY templates /opt/agentic/templates
COPY --chmod=755 image/entrypoint.sh /opt/agentic/entrypoint.sh
COPY image/profile.d/agentic.sh /etc/profile.d/agentic.sh
COPY image/tmux.conf /etc/tmux.conf
RUN ln -sf /opt/agentic/bin/* /usr/local/bin/ \
 && printf '%s\n' '[ -f /etc/profile.d/agentic.sh ] && . /etc/profile.d/agentic.sh' \
      '[ -f "$HOME/.agentic/env" ] && . "$HOME/.agentic/env"' >> /etc/bash.bashrc \
 && chmod -R a+rX /opt/agentic

# Base plugins, baked so a container needs no network to have them
USER dev
WORKDIR /home/dev
RUN mkdir -p /home/dev/.claude \
 && ln -sfn /opt/agentic/claude-plugins /home/dev/.claude/plugins \
 && agentic-install-plugins "$(yq -o=json -I=0 '{"claude": .plugins.claude, "marketplaces": .plugins.marketplaces}' /opt/agentic/config/defaults.yaml)"

# What this image has, for the setup skill; derived images rewrite it
USER root
RUN agentic-inventory > /opt/agentic/inventory.txt
USER dev

WORKDIR /work
ENTRYPOINT ["/opt/agentic/entrypoint.sh"]
CMD ["bash"]
