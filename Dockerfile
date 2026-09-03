# syntax=docker/dockerfile:1.6
# ==============================================================================
# 代码安全与可靠性检查器 - 集成运行镜像
# 可部署到：GitHub Actions (container://) / GitLab CI (image:) / 本地 Docker run
#
# 构建命令:
#   docker build -t code-safety-checker:latest .
#   docker tag  code-safety-checker:latest registry.example.com/your-org/code-safety-checker:latest
#   docker push registry.example.com/your-org/code-safety-checker:latest
#
# 运行:
#   docker run --rm -v /path/to/target-repo:/repo:ro \
#     -v /path/to/output:/app/reports:rw \
#     code-safety-checker:latest --dir /repo --strict
# ==============================================================================

FROM ubuntu:24.04 AS base
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PIP_NO_CACHE_DIR=true \
    NPM_CONFIG_LOGLEVEL=warn \
    PATH="/usr/local/go/bin:/root/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---- 系统基础依赖 ----
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget tar unzip gzip xz-utils jq \
        git openssh-client gnupg lsb-release software-properties-common \
        build-essential pkg-config file \
        python3 python3-pip python3-venv python3-dev \
  && rm -rf /var/lib/apt/lists/* \
  && ln -sf /usr/bin/python3 /usr/bin/python \
  && ln -sf /usr/bin/pip3    /usr/bin/pip

# ---- Node.js 20 LTS ----
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --silent npm@latest corepack pnpm yarn \
 && corepack enable

# ---- Go 1.22 ----
RUN curl -fsSL https://go.dev/dl/go1.22.5.linux-amd64.tar.gz \
  | tar -xz -C /usr/local \
 && go version

# ==============================================================================
# 安装各类扫描工具（按层缓存，大工具靠前）
# ==============================================================================

# gitleaks
RUN VER=$(curl -sL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | jq -r '.tag_name') \
 && curl -sL "https://github.com/gitleaks/gitleaks/releases/download/${VER}/gitleaks_${VER#v}_linux_x64.tar.gz" \
    | tar -xz -C /usr/local/bin gitleaks \
 && gitleaks version

# trivy (镜像/文件系统/IaC/依赖漏洞一站式)
RUN curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b /usr/local/bin v0.52.0 \
 && trivy --version \
 && trivy image --download-db-only --no-progress 2>&1 | tail -3 || true

# semgrep (通用跨语言 SAST)
RUN python -m pip install --quiet --upgrade pip setuptools wheel \
 && python -m pip install --quiet --no-cache-dir semgrep==1.76.0 \
 && semgrep --version

# Python 安全/许可证
RUN python -m pip install --quiet --no-cache-dir \
        bandit==1.7.9 \
        pip-audit==2.7.3 \
        pip-licenses==5.0.0 \
        safety==3.2.8 \
        checkov==3.2.203 \
 && bandit --version

# Go 安全工具
RUN go install github.com/securecodewarrior/gosec/v2/cmd/gosec@v2.20.0 \
 && go install golang.org/x/vuln/cmd/govulncheck@latest \
 && gosec --version 2>&1 | head -2 || true \
 && govulncheck --version 2>&1 | head -2 || true

# npm 全局工具 (license / eslint / snyk)
RUN npm install -g --silent --no-audit --no-fund \
        license-checker-rseidelsohn@4 \
        eslint@8 @eslint/js@9 typescript-eslint@8 \
        snyk@latest 2>&1 | tail -3 \
 && eslint --version

# ==============================================================================
# 拷贝本 checker 项目脚本
# ==============================================================================
FROM base AS final

WORKDIR /app
COPY scripts/   /app/scripts/
COPY config/    /app/config/

RUN chmod +x /app/scripts/*.sh \
 && ln -sf /app/scripts/run-checks.sh /usr/local/bin/code-safety-checker \
 && mkdir -p /app/reports \
 && echo "export CHECKER_ROOT=/app" > /etc/profile.d/code-safety-checker.sh \
 && /app/scripts/run-checks.sh --help | head -10

ENV CHECKER_ROOT=/app \
    REPORT_DIR=/app/reports

ENTRYPOINT ["/app/scripts/run-checks.sh"]
CMD ["--help"]
