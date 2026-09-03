# ==============================================================================
# Makefile - 便捷命令入口
# 使用: make help 查看全部命令
# ==============================================================================

SHELL := /bin/bash
CHECKER_ROOT := $(shell pwd)
REPORT_DIR   ?= $(CHECKER_ROOT)/reports
TARGET_DIR   ?= $(CURDIR)
IMAGE_NAME   ?= code-safety-checker
IMAGE_TAG    ?= latest

.PHONY: help install-tools check check-full check-fast check-secret check-dep check-frontend check-backend check-iac check-license review install-hooks check-remote check-repos docker-build docker-run docker-push github-install gitlab-install self-test clean

help: ## 显示帮助
	@awk 'BEGIN {FS = ":.*##"; printf "\n使用: make \033[36m<命令>\033[0m [变量=值]\n\n命令:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } END { print "" }' $(MAKEFILE_LIST)
	@echo "常用变量:"
	@echo "  TARGET_DIR=路径     指定被扫描仓库 (默认当前目录)"
	@echo "  REPORT_DIR=路径     指定报告输出目录 (默认 ./reports)"
	@echo "  STRICT=true         开启严格模式"
	@echo "  IMAGE_NAME=x        自定义 Docker 镜像名"
	@echo ""

# ---------------- 工具安装 ----------------
install-tools: ## 安装推荐的外部工具 (需要 sudo)
	@echo "→ 安装系统级工具 (需要 sudo 权限)"
	-sudo apt-get update
	-sudo apt-get install -y jq curl wget tar unzip
	@echo "→ 安装 gitleaks"
	-VER=$$(curl -sL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'])") ; \
	 curl -sL "https://github.com/gitleaks/gitleaks/releases/download/$${VER}/gitleaks_$${VER#v}_linux_x64.tar.gz" | sudo tar -xz -C /usr/local/bin gitleaks || \
	 curl -sL "https://github.com/gitleaks/gitleaks/releases/download/$${VER}/gitleaks_$${VER#v}_darwin_x64.tar.gz" | sudo tar -xz -C /usr/local/bin gitleaks
	@gitleaks version || echo "gitleaks 安装失败，请手动安装"
	@echo "→ 安装 Python 安全工具"
	-python3 -m pip install --user --upgrade pip
	-python3 -m pip install --user semgrep bandit pip-audit pip-licenses safety checkov
	@echo "→ 安装 npm 全局工具"
	-npm install -g license-checker-rseidelsohn eslint
	@echo "→ 安装 trivy (Ubuntu/macOS)"
	-curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin
	@echo "✅ 安装完成，运行 make self-test 验证"

# ---------------- 检查命令 ----------------
CHECKER_BIN := $(CHECKER_ROOT)/scripts/run-checks.sh
chmod_bin:
	@chmod +x $(CHECKER_ROOT)/scripts/*.sh

check: chmod_bin ## 执行全量检查 (TARGET_DIR=xxx)
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) $(if $(STRICT),--strict)

check-fast: chmod_bin ## 快速扫描 (跳过 IaC / License)
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --skip iac,license $(if $(STRICT),--strict)

check-security: chmod_bin ## 仅安全维度: secret + frontend + backend + dep
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --only secret,dep,frontend,backend $(if $(STRICT),--strict)

check-secret: chmod_bin ## 仅检查敏感信息泄露
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --only secret

check-dep: chmod_bin ## 仅检查依赖漏洞
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --only dep

check-frontend: chmod_bin ## 仅检查前端代码
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --only frontend

check-backend: chmod_bin ## 仅检查后端代码
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --only backend

check-iac: chmod_bin ## 仅检查 IaC / Dockerfile
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --only iac

check-license: chmod_bin ## 仅检查许可证合规
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(TARGET_DIR) --only license

review: ## 本地快速安全审查（macOS/Linux 通用，秒级，不依赖外部工具）
	@chmod +x $(CHECKER_ROOT)/scripts/review.sh
	@$(CHECKER_ROOT)/scripts/review.sh --dir $(TARGET_DIR)

install-hooks: ## 安装「提交前安全审查」hook 到目标仓库 (TARGET_DIR=xxx)
	@chmod +x $(CHECKER_ROOT)/scripts/install-git-hooks.sh
	@$(CHECKER_ROOT)/scripts/install-git-hooks.sh $(TARGET_DIR)

install-hooks-global: ## 安装到全局 git 模板（对新仓库自动生效）
	@chmod +x $(CHECKER_ROOT)/scripts/install-git-hooks.sh
	@$(CHECKER_ROOT)/scripts/install-git-hooks.sh --global

# ---------------- 远程仓库检查 ----------------
check-remote: ## 检查远程 GitHub 仓库 (make check-remote REPO_URL=git@...:owner/repo.git)
	@chmod +x $(CHECKER_ROOT)/scripts/check-remote.sh
	@$(CHECKER_ROOT)/scripts/check-remote.sh $(REPO_URL) $(if $(BRANCH),--branch $(BRANCH)) \
		$(if $(ONLY),--only $(ONLY)) $(if $(SKIP),--skip $(SKIP)) $(if $(STRICT),--strict)

check-repos: ## 批量检查 config/repos.json 中的所有仓库
	@chmod +x $(CHECKER_ROOT)/scripts/check-repos.sh
	@$(CHECKER_ROOT)/scripts/check-repos.sh $(if $(ONLY),--only $(ONLY)) $(if $(SKIP),--skip $(SKIP)) \
		$(if $(STRICT),--strict) $(if $(FILTER),--filter $(FILTER))

# ---------------- Docker ----------------
docker-build: ## 构建 Docker 镜像
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) -f Dockerfile .

docker-run: ## 用 Docker 运行检查 (make docker-run TARGET_DIR=/path/to/repo)
	@mkdir -p $(REPORT_DIR)
	docker run --rm \
		-v "$(abspath $(TARGET_DIR)):/repo:ro" \
		-v "$(abspath $(REPORT_DIR)):/app/reports:rw" \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		--dir /repo $(if $(STRICT),--strict) $(OPTS)

docker-push: ## 推送镜像到镜像仓库
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# ---------------- CI 安装辅助 ----------------
github-install: ## 一键复制 GitHub Actions 到当前目标仓库
	@[ -d "$(TARGET_DIR)/.github/workflows" ] || mkdir -p "$(TARGET_DIR)/.github/workflows"
	cp .github/workflows/code-safety-check.yml "$(TARGET_DIR)/.github/workflows/"
	@echo "✅ 已复制到 $(TARGET_DIR)/.github/workflows/code-safety-check.yml"
	@echo "请编辑此文件顶部的 CHECKER_REPO / CHECKER_REF 变量"

gitlab-install: ## 一键复制 .gitlab-ci.yml include 模板到目标仓库
	@cp .gitlab-ci.yml "$(TARGET_DIR)/.code-safety-checker.yml"
	@echo "# 请在 $(TARGET_DIR)/.gitlab-ci.yml 顶部加入:"
	@echo "include:"
	@echo "  - local: '.code-safety-checker.yml'"
	@echo "或者（如果单独部署了模板仓库）:"
	@echo "include:"
	@echo "  - project: 'your-org/code-safety-checker'"
	@echo "    ref: 'main'"
	@echo "    file: '.gitlab-ci.yml'"

# ---------------- 自检 ----------------
self-test: chmod_bin ## 自检: 用本 checker 仓库自身跑一轮
	@REPORT_DIR=$(REPORT_DIR) $(CHECKER_BIN) --dir $(CHECKER_ROOT) \
		--skip iac --strict || true
	@echo "报告位于: $(REPORT_DIR)"

clean: ## 清理报告目录
	@rm -rf $(REPORT_DIR)/*
	@echo "✅ 已清理 $(REPORT_DIR)"
