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
│   ├── secret-patterns.json      # 敏感信息自定义正则 + 白名单
│   └── repos.json                # 批量检查的远程仓库清单（check-repos.sh 读取）
├── scripts/
│   ├── run-checks.sh             # ⭐ 主入口 (所有入口最终都走这里)
│   ├── check-remote.sh           # ⭐ 远程 GitHub 仓库一键检查（clone+检查+生成报告文档）
│   ├── check-repos.sh            # ⭐ 批量检查 config/repos.json 中所有远程仓库
│   ├── utils.sh                  # 日志/颜色/统计/报告生成
│   ├── secret-scan.sh            # 敏感信息扫描
│   ├── dependency-scan.sh        # 依赖漏洞扫描
│   ├── frontend-check.sh         # 前端安全 + 质量
│   ├── backend-check.sh          # 后端安全 + 可靠性
│   ├── iac-container-check.sh    # IaC / Dockerfile / 容器镜像
│   └── license-check.sh          # 许可证合规
└── reports/                      # 运行时产出的报告目录（每个被检仓库一个子目录）
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

### 方式一·补充 2：直接检查远程 GitHub 仓库（一键出报告文档）

不想把 checker 装进目标仓库？只要给一个 GitHub 仓库地址，本工具会自动 clone → 全量检查 → 生成独立 Markdown 检查文档。**支持 HTTPS 与 SSH 两种地址**。

```bash
# 单个仓库一键检查（最常用）
./scripts/check-remote.sh https://github.com/owner/repo.git
./scripts/check-remote.sh git@github.com:owner/repo.git --strict

# 指定分支 / 只跑部分检查 / 浅克隆深度
./scripts/check-remote.sh git@github.com:owner/repo.git --branch dev --only secret,dep
./scripts/check-remote.sh https://github.com/owner/repo.git --depth 0   # 0=全量历史（敏感信息扫描更彻底）

# 等价 Makefile 用法
make check-remote REPO_URL=git@github.com:owner/repo.git STRICT=true
```

**产出**：`reports/<仓库名>/<时间戳>-report.md`（同时更新 `latest-report.md` 指向最新一次），包含总体结论、仓库与提交信息、检查汇总统计表、各检查项明细、完整原始输出，以及 `reports/<仓库名>/` 下各检查项的原始产物文件。

#### 批量检查多个仓库（清单驱动）

把要巡检的仓库地址写进 [config/repos.json](config/repos.json)（每条可单独配置 `branch`/`strict`/`only`/`skip`/`enabled`），然后一条命令全部检查并生成总览：

```bash
# 检查 repos.json 中所有 enabled=true 的仓库
./scripts/check-repos.sh

# 对所有仓库只跑敏感信息 + 依赖；或只检查名称匹配的仓库
./scripts/check-repos.sh --only secret,dep
./scripts/check-repos.sh --filter code-safety

# 等价 Makefile 用法
make check-repos STRICT=true
```

**产出**：每个仓库一份 `reports/<仓库名>/latest-report.md`，外加 `reports/index.md` 总览表格（列出每个仓库的通过/失败、退出码与报告链接）。任一仓库失败则整体退出码非 0，便于接入定时巡检 / 定时任务。

> 💡 `repos.json` 里把 `"enabled"` 设为 `false` 可临时跳过某仓库而无需删除条目；`check-repos.sh --filter <关键字>` 可只检查名称匹配的仓库。

---

### 方式二：部署到 GitHub Actions（PR 强制检查）

#### Step 1. 把本 checker 项目推到你的组织下

```bash
gh repo create your-org/code-safety-checker --public --source=. --push
# 或
git remote add origin git@github.com:your-org/code-safety-checker.git
git push -u origin main
```

#### Step 2. 在每个业务仓库的 `.github/workflows/` 下创建【调用方】工作流

一条命令搞定（推荐）：

```bash
cd /path/to/code-safety-checker
make github-install CHECKER_ORG=your-org TARGET_DIR=/path/to/business-repo
```

或者手写（**注意：业务仓库里只需要这一个文件**）：

```yaml
# business-repo/.github/workflows/safety.yml
name: safety

on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [main, master]

permissions:
  contents: read
  pull-requests: write
  checks: write

concurrency:
  # ⚠️ concurrency 只写在「顶层调用方」这一层
  group: safety-${{ github.workflow }}-${{ github.event.pull_request.head.ref || github.ref }}
  cancel-in-progress: true

jobs:
  safety:
    uses: your-org/code-safety-checker/.github/workflows/code-safety-check.yml@main
    with:
      strict: true
    secrets: inherit        # checker 为私有仓库时需要
```

> ⚠️ **不要**把 `.github/workflows/code-safety-check.yml` 直接复制到业务仓库后再自己加 `push` 触发器 —— 那会让同一个文件既是「顶层工作流」又是「被调用工作流」，触发 GitHub 的并发死锁（详见下方 FAQ）。
>
> 若确实要内嵌副本，用 `make github-install-embedded CHECKER_ORG=your-org TARGET_DIR=...`（会自动保证可复用文件只保留 `workflow_call`）。

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

### 方式二+：部署到 Gitee Go（合并请求强制检查）

国内团队如使用 Gitee，可通过 Gitee Go 流水线实现等价的能力（合并请求自动检查 + 评论报告 + 流水线失败阻塞合并）。

#### Step 1. 可选：把 checker 仓库导入到 Gitee（加速国内拉取）

打开 **https://gitee.com/projects/import** → 填写 `https://github.com/jimGJW/code-safety-checker.git` → 导入后记下 Gitee 仓库地址（例如 `https://gitee.com/your-org/code-safety-checker.git`）。跳过此步则默认从 GitHub 拉取（国内网络可能较慢）。

#### Step 2. 创建 Gitee 私人令牌

打开 **https://gitee.com/profile/personal_access_tokens** → 生成新令牌，权限勾选：
- `projects`、`pull_requests`、`notes`、`user_info`

复制令牌字符串（下一步要用，只会显示一次）。

#### Step 3. 在业务仓库添加流水线变量

进入 **业务仓库 → 管理 → 流水线 → 流水线变量** → 新增：
| 变量名 | 值 | 说明 |
|--------|----|------|
| `GITEE_TOKEN` | 上一步生成的私人令牌 | 用于 API 写评论、写 commit 状态 |

#### Step 4. 在业务仓库添加流水线文件

把本仓库的 **[.gitee/workflow/code-safety.yml](.gitee/workflow/code-safety.yml)** 复制到业务仓库的 `.workflow/code-safety.yml`，然后按注释调整 `CHECKER_REPO` / `STRICT` / `ONLY` / `SKIP`。

或通过本仓库 Makefile 一键复制：
```bash
make gitee-install TARGET_DIR=/path/to/business-repo
```

然后 push 到 main/master。

#### Step 5. 开启「必须通过流水线才能合并」

进入 **业务仓库 → 设置 → 合并请求设置**（**https://gitee.com/<owner>/<repo>/settings#merge_request**）：
- 勾选 **合并请求必须通过流水线才能合并**
- 建议同时勾选 **合并请求必须通过测试**、**禁止直接推送代码到 master/main**

#### 效果
- 新建 / 更新合并请求时 Gitee Go 自动触发检查
- 机器人会把「检查汇总 + 日志摘要」**评论到合并请求内**
- 合并请求 commit 会显示 **code-safety-checker** 的状态徽标（pending/success/failure）
- 失败则流水线失败，合并按钮被置灰禁用

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

**Q6: GitHub Actions 报 `Canceling since a deadlock was detected for concurrency group ... between a top level workflow and 'safety'`，每次提交都出现？**

这是 **同一个工作流既被 `push` 触发（顶层运行）、又被 `uses:` 调用（嵌套运行）**，两次运行抢同一个 `concurrency.group`，GitHub 判定死锁并取消其中一条。

修复三步：

1. **可复用文件只保留 `workflow_call`** —— 删掉 `code-safety-check.yml` 里的 `pull_request` / `push` 触发器，**并移除它的 `concurrency:` 段**：
   ```yaml
   on:
     workflow_call:
     workflow_dispatch:   # 可选，用于手动跑
   # ❌ 不要 pull_request / push
   # ❌ 不要 concurrency
   ```
2. **`concurrency` 只写在调用方**（`safety.yml`）这一层：
   ```yaml
   concurrency:
     group: safety-${{ github.workflow }}-${{ github.event.pull_request.head.ref || github.ref }}
     cancel-in-progress: true
   ```
3. **清理业务仓库里的重复文件**：如果 `.github/workflows/` 下同时存在 `code-safety-check.yml`（还带 push 触发器）和 `safety.yml`，删掉或改名前者：
   ```bash
   git rm .github/workflows/code-safety-check.yml
   ```

> 本仓库已按此规范修好：`.github/workflows/code-safety-check.yml` 只做可复用；
> 检查器自身的 CI 走 `.github/workflows/self-check.yml`；业务仓库模板见 `templates/github/safety.yml`。

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
