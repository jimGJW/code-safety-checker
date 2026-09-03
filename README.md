# 🔒 Code Safety & Reliability Checker

> **一套开箱即用的代码安全与可靠性检查框架，可直接部署在 GitHub Actions 和 GitLab CI 中，作为 Pull Request / Merge Request 的「强制门禁」，**阻止**存在安全漏洞、敏感信息泄露、高危依赖、许可证合规风险、可靠性缺陷的代码合入主分支。

---

## ✨ 功能总览

| 检查维度          | 说明                                                                          | 支持栈/引擎                                                                                          |
|-------------------|-----------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| 🔑 **敏感信息泄露**    | 扫描提交历史 + 工作区是否硬编码密钥、密码、Token、私钥、Webhook、DB URL 等          | gitleaks（历史+文件） + TruffleHog + 内置 10+ 自定义正则                                             |
| 📦 **依赖漏洞**         | 扫描第三方依赖已知漏洞，按 CVSS 分级告警并阻塞高危                                 | npm audit / pnpm audit / yarn audit / pip-audit / govulncheck / OWASP dependency-check (mvn/gradle) |
| 🎨 **前端安全**         | XSS、eval、dangerouslySetInnerHTML、v-html、硬编码密钥、CSP、localStorage 存密码等 | ESLint（项目自带规则）+ Semgrep + 内置 16 条正则                                                     |
| ⚙️ **后端安全**         | SQL 注入、命令注入、路径穿越、SSRF、XXE、反序列化、认证绕过、不安全加密、硬编码密钥    | Bandit (Python) / gosec (Go) / Semgrep + 内置 20+ 跨语言规则                                         |
| 🛠️ **后端可靠性**       | 输入校验、错误处理中间件、panic recover、资源泄露、空指针、超时配置                   | 内置规则                                                                                              |
| 🐳 **IaC / 容器**        | Dockerfile 最佳实践、Terraform SG 0.0.0.0、K8s 特权容器/root/latest/resources.limits  + 镜像漏洞 | Trivy / Dockle + 内置规则                                                                            |
| 📜 **许可证合规**        | 防止 GPL/AGPL/SSPL 等"传染性"许可证进入商业项目，支持 npm + Python 依赖              | license-checker / pip-licenses + 内置白/黑名单                                                       |

> **零依赖兜底**：所有检查都有**内置 grep 实现**，即使不安装外部工具也能产出有效结果；安装外部工具后自动升级到更精准的引擎。

---

## 📁 项目结构

```
code-safety-checker/
├── Makefile                      # 便捷命令入口 (make help)
├── Dockerfile                    # 一键构建检查器运行镜像 (github/gitlab 通用)
├── .github/workflows/
│   └── code-safety-check.yml     # GitHub Actions 集成（PR 阻塞 + 评论 + Artifacts）
├── .gitlab-ci.yml                # GitLab CI 模板（可作为 include 模板复用）
├── config/
│   ├── check-config.json         # 检查器配置：开关、严重度阈值、规则
│   └── secret-patterns.json      # 敏感信息自定义正则 + 白名单
├── scripts/
│   ├── run-checks.sh             # ⭐ 主入口 (所有入口最终都走这里)
│   ├── utils.sh                  # 日志/颜色/统计/报告生成
│   ├── secret-scan.sh            # 敏感信息扫描
│   ├── dependency-scan.sh        # 依赖漏洞扫描
│   ├── frontend-check.sh         # 前端安全 + 质量
│   ├── backend-check.sh          # 后端安全 + 可靠性
│   ├── iac-container-check.sh    # IaC / Dockerfile / 容器镜像
│   └── license-check.sh          # 许可证合规
└── reports/                      # 运行时产出的报告目录
```

---

## 🚀 快速开始（3 种使用方式）

### 方式一：本地直接运行（10 秒上手）

```bash
# 1. 克隆本仓库
git clone https://github.com/your-org/code-safety-checker.git
cd code-safety-checker
chmod +x scripts/*.sh

# 2. 直接扫描目标仓库（所有检查）
./scripts/run-checks.sh --dir /path/to/your-repo

# 3. 快速模式（跳过 IaC/License，适合 PR 快路径）
./scripts/run-checks.sh --dir /path/to/your-repo --skip iac,license

# 4. 只跑前端 + 敏感信息
./scripts/run-checks.sh --dir /path/to/your-repo --only secret,frontend

# 5. 严格模式（中危及以上就阻塞合并）
./scripts/run-checks.sh --dir /path/to/your-repo --strict

# 或者用 Makefile 一条命令:
make check TARGET_DIR=/path/to/your-repo STRICT=true
```

退出码：
- `0` → 全部通过
- `1` → 存在阻塞性问题，可直接用于 `&&` 链式阻塞命令。

报告目录：`reports/`（含 JSON + Markdown + 纯文本，可导入其他系统）。

> ⚠️ **macOS 本地运行说明**：`run-checks.sh` 依赖 bash 4+（`declare -A`）与 GNU grep（`grep -P`），在 Linux / Docker / GitHub Actions 中开箱即用；macOS 自带 bash 3.2 与 toybox grep 不支持。因此额外提供一套**零依赖的本地快速审查引擎 `review.sh`**（见下方「方式一·补充」），专为本地提交前快速门禁设计，macOS/Linux 通用。

---

### 方式一·补充：本地快速审查 + 提交前自动 hook

```bash
# 快速审查整个目录（密钥 + eval / v-html / 命令注入拼接 / SQL 拼接等常见高危模式）
./scripts/review.sh --dir /path/to/your-repo

# 仅审查 git 暂存区文件（提交前门禁，秒级）
cd /path/to/your-repo && /path/to/checker/scripts/review.sh --staged

# 审查与某分支的差异（merge / PR review 场景）
./scripts/review.sh --diff origin/main
```

**一键安装「提交前自动审查」hook（SourceTree / 命令行 git / IDE 全部通用）：**

```bash
# 安装到指定仓库
./scripts/install-git-hooks.sh /path/to/your-repo

# 或安装到全局 git 模板（对之后新 init/clone 的仓库自动生效）
./scripts/install-git-hooks.sh --global

# 也可用 Makefile
make install-hooks TARGET_DIR=/path/to/your-repo
```

安装后，任何 git 客户端每次 `commit` 都会自动扫描暂存文件，命中 critical/high 密钥时阻止提交并打印审查结论；`git commit --no-verify` 或 `SKIP_SAFETY=1 git commit` 可临时强制跳过。

---

### 方式二：部署到 GitHub Actions（PR 强制检查）

#### Step 1. 把本 checker 项目推到你的组织下

```bash
gh repo create your-org/code-safety-checker --public --source=. --push
# 或
git remote add origin git@github.com:your-org/code-safety-checker.git
git push -u origin main
```

#### Step 2. 在每个业务仓库的 `.github/workflows/` 下创建工作流

直接复制本仓库的 `.github/workflows/code-safety-check.yml`，或者在业务仓库顶部写：

```yaml
# business-repo/.github/workflows/code-safety.yml
name: Call Code Safety Checker
on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [main, master]

jobs:
  call-safety-check:
    uses: your-org/code-safety-checker/.github/workflows/code-safety-check.yml@main
    # 如果 checker 是私有仓库，需要 secrets 传入 PAT
    secrets: inherit
```

> 如果想用更简单的"内嵌副本"方式：直接执行本仓库的 `make github-install TARGET_DIR=/path/to/business-repo`。

#### Step 3. 设置为 Required Check（重要！才能真正阻塞 PR）

1. 打开业务仓库 → **Settings → Branches → Branch protection rule**（保护 main/master）
2. 勾选 **Require status checks to pass before merging**
3. 搜索并选中 `Code Safety Check` + `快速敏感信息扫描 (Diff 模式)`（运行一次后才能搜到）
4. 可选：勾选 `Require branches to be up to date before merging`

#### Step 4. 效果

- 创建 / 更新 PR 时，自动运行所有检查
- 检查结果会**直接评论到 PR**（通过/失败、问题数、下载 Artifacts 链接）
- **不通过的 PR 无法合并**（有绿色按钮保护）
- 管理员可打标签 `skip-safety-check` 临时跳过（极个别情况），或打 `safety-strict` 启用严格模式

---

### 方式三：部署到 GitLab CI（MR 强制检查）

#### Step 1. 将本 checker 推到 GitLab 项目

```bash
git remote add origin git@gitlab.example.com:your-org/code-safety-checker.git
git push -u origin main
```

#### Step 2. 推荐：构建 Docker 镜像加速（可选但强烈推荐）

```bash
# 构建包含所有工具的运行镜像（约 3GB，节省每个 pipeline 的下载时间）
docker build -t registry.example.com/your-org/code-safety-checker:latest .
docker push registry.example.com/your-org/code-safety-checker:latest
```

然后在 CI/CD Variables 中设置：
```
SAFETY_CHECKER_IMAGE = registry.example.com/your-org/code-safety-checker:latest
```

#### Step 3. 在业务仓库 `.gitlab-ci.yml` 中引用

```yaml
# business-repo/.gitlab-ci.yml
stages:
  - build
  - test
  - deploy

include:
  # 直接从模板仓库 include
  - project: 'your-org/code-safety-checker'
    ref: 'main'
    file: '.gitlab-ci.yml'

# 可选：覆盖变量（每个项目按需）
variables:
  CHECK_SECRET:  "true"
  CHECK_DEP:     "true"
  CHECK_FRONTEND: "auto"   # auto 表示自动识别，非前端项目自动跳过
  CHECK_BACKEND:  "auto"
  CHECK_IAC:      "auto"
  CHECK_LICENSE:  "true"
  STRICT_MODE:   "false"   # 改为 "true" 即阻塞中危及以上

build-job:
  stage: build
  script: echo "your build here"
```

#### Step 4. 开启「Pipeline 必须通过」

1. 业务仓库 → **Settings → Merge requests**
2. 勾选 **Pipelines must succeed**
3. 可选：**Enable merged results pipelines** + **Enable pipeline for merged results**（更真实地模拟合并后结果）

#### Step 5. 可选：配置 MR 自动评论

在业务仓库 **Settings → Access Tokens** 生成一个 `api` 权限的 Project Access Token，添加到该项目或 Group 的 **CI/CD Variables**：

```
Key: GITLAB_API_TOKEN
Value: glpat-xxxxxxxxxxxxx
Protect: true  Mask: true
```

这样每次跑完会自动在 MR 发一条结构化评论。

---

## 🐳 作为 Docker 镜像通用运行（GitHub / GitLab / Jenkins 都可）

```bash
# 构建
docker build -t code-safety-checker:latest .

# 扫描本地仓库
docker run --rm \
  -v /home/user/projects/my-repo:/repo:ro \
  -v $(pwd)/reports:/app/reports:rw \
  code-safety-checker:latest --dir /repo --strict

# 只跑 secret + dep
docker run --rm ... code-safety-checker:latest --dir /repo --only secret,dep
```

在 Jenkins 中：
```groovy
stage('Safety Check') {
  agent { docker { image 'registry.example.com/your-org/code-safety-checker:latest' args '-u root:root' } }
  steps {
    sh '/app/scripts/run-checks.sh --dir . --strict'
  }
  post { always { archiveArtifacts artifacts: 'reports/**' } }
}
```

---

## ⚙️ 配置指南

### `config/check-config.json` - 检查项开关

```json
{
  "global": {
    "fail_on_severity": "medium",   // 达到哪个级别就失败
    "timeout_seconds": 1800         // 单个模块超时
  },
  "checks": {
    "secret_scan":              { "enabled": true },
    "dependency_vulnerability": { "enabled": true, "fail_on_cvss": 7.0 },
    "frontend":                 { "enabled": "auto" },   // auto=自动识别
    "backend":                  { "enabled": "auto" },
    "iac_scan":                 { "enabled": "auto" },
    "container_scan":           { "enabled": "auto" },
    "license_check":            { "enabled": true }
  }
}
```

### `config/secret-patterns.json` - 扩展密钥正则

在 `patterns` 数组中添加你公司的专属密钥模式（例如内部的 `Corp_AK_` 前缀）即可。

### 命令行参数总览

```
./scripts/run-checks.sh [选项]

  -d, --dir <path>       扫描目录 (默认: 当前目录)
  -o, --only <list>      仅执行: secret,dep,frontend,backend,iac,license
  -s, --skip <list>      跳过指定项
      --strict           严格模式 (中危及以上就失败)
      --debug            调试输出
  -h, --help             帮助
```

---

## 🧪 支持的技术栈

| 领域 | 技术栈 |
|------|--------|
| 前端 | Vue / React / Angular / Svelte / Next.js / Nuxt / 原生 JS/TS |
| 后端 | Node.js/Express/Nest、Python/Django/FastAPI/Flask、Go/gin/fiber、Java/SpringBoot、Ruby on Rails、Rust、PHP |
| IaC  | Dockerfile、Docker Compose、Terraform、Kubernetes YAML、Helm |
| 包管理 | npm / pnpm / yarn / pip / poetry / pipenv / go mod / Maven / Gradle |

> **未知栈**也可以运行：内置规则基于语义正则，不依赖特定语言框架。

---

## 🔧 常见问题 (FAQ)

**Q1: 误报太多怎么办？**
- 对于**密钥类**：在 `config/secret-patterns.json` 的 `allowlist.strings` / `allowlist.files` 添加白名单；或在代码行尾加注释 `// gitleaks:allow` / `# nosec`。
- 对于**静态分析**：按文件、按规则支持扩展黑名单，也可加 `// eslint-disable-next-line` 等语法标记。

**Q2: 如何临时跳过检查（紧急上线）？**
- **GitHub**: PR 打标签 `skip-safety-check`。
- **GitLab**: Git 提交信息加 `[skip safety]`（可自行在 rules 中扩展）或使用 `manual` job。
- **命令行**: `--skip <检查项>`。

**Q3: 历史提交中发现大量密钥，怎么处理？**
1. 立刻轮换所有已泄露的密钥！
2. 用 [`git-filter-repo`](https://github.com/newren/git-filter-repo) 或 [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/) 重写历史。
3. 如果是公开仓库：通知 GitHub/GitLab 支持撤销 fork 中的副本（很重要）。

**Q4: 检查太慢了，如何加速？**
- 按项目配置 `--only`，例如纯前端项目 `--only secret,dep,frontend`。
- 预构建 Docker 镜像（避免每次下载几十上百个工具）。
- CI 中开启工具缓存：`npm cache` / `pip cache` / `go build cache`。
- MR 快路径与完整扫描拆分：本模板 GitHub/GitLab 中已内置 `quick-secret-scan` 早期 job。

**Q5: 如何和内部 IM 打通（飞书/钉钉/企微/Slack）？**
- 在 `scripts/utils.sh:ci_markdown_summary()` 扩展通知逻辑；或在 CI 的最后一步 `curl` 到相应 webhook，传入 `reports/ci-summary.md` 内容即可。

---

## 📌 部署路线图（推荐）

```
Day 1   本地跑：make install-tools → make check TARGET_DIR=xxx
Day 2   部署到 GitHub/GitLab 单项目，验证效果
Day 3   1) 构建并推送 Docker 镜像  2) 组织内 include/uses 复用
Day 5   全项目开启 Required Check / Pipeline must succeed
Week 2  1) 接入 IM 告警  2) 扩展公司自定义规则  3) 和 SBOM 系统打通
Month 1 引入企业 SCA/SAST 付费工具（如 Snyk/SonarQube）作为补充
```

---

## 📄 License

本检查器框架本身采用 MIT 许可证（可自由用于商业闭源项目）。但被扫描的第三方依赖仍需遵循其各自许可证，请务必开启 `license-check` 模块。

---

**Made with ❤️ 为守护每一行代码的安全与可靠而生。**
