#!/usr/bin/env bash
# ==============================================================================
# check-remote.sh —— 远程 GitHub 仓库一键检查入口
#
# 功能：
#   传入一个 GitHub 仓库地址（HTTPS 或 SSH），自动 clone 到临时目录，
#   跑全量安全与可靠性检查，生成独立的 Markdown 检查文档保存到
#   reports/<repo-name>/<timestamp>-report.md（同时更新 latest-report.md）。
#
# 用法:
#   ./scripts/check-remote.sh <github-url> [选项]
#
# 选项:
#   -b, --branch <name>    指定分支（默认: 仓库默认分支）
#   -d, --depth <n>        clone 深度（默认: 1，浅克隆加速；历史敏感信息扫描需完整历史时设 0 表示全量）
#   -o, --only <list>      只执行指定检查: secret,dep,frontend,backend,iac,license
#   -s, --skip <list>      跳过指定检查
#       --strict           严格模式：medium 及以上问题视为失败
#       --no-cleanup       检查完保留 clone 的临时目录（便于排查）
#   -h, --help             显示帮助
#
# 示例:
#   ./scripts/check-remote.sh https://github.com/octocat/Hello-World.git
#   ./scripts/check-remote.sh git@github.com:jimGJW/code-safety-checker.git --strict
#   ./scripts/check-remote.sh https://github.com/xxx/yyy.git --only secret,dep --branch dev
# ==============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -------------------- 参数解析 --------------------
REPO_URL=""
BRANCH=""
DEPTH=1
ONLY=""
SKIP=""
STRICT=false
NO_CLEANUP=false

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--branch)    BRANCH="$2"; shift 2 ;;
    -d|--depth)     DEPTH="$2"; shift 2 ;;
    -o|--only)      ONLY="$2"; shift 2 ;;
    -s|--skip)      SKIP="$2"; shift 2 ;;
    --strict)       STRICT=true; shift ;;
    --no-cleanup)   NO_CLEANUP=true; shift ;;
    -h|--help)      usage ;;
    -*)             echo "未知选项: $1"; exit 2 ;;
    *)              [[ -z "$REPO_URL" ]] && REPO_URL="$1" || { echo "多余的参数: $1"; exit 2; }; shift ;;
  esac
done

if [[ -z "$REPO_URL" ]]; then
  echo "用法: $0 <github-url> [选项]"
  echo "示例: $0 https://github.com/octocat/Hello-World.git"
  exit 2
fi

# -------------------- 派生仓库信息 --------------------
# 从 URL 提取 owner/repo，兼容:
#   https://github.com/owner/repo.git
#   https://github.com/owner/repo
#   git@github.com:owner/repo.git
extract_repo_name() {
  local url="$1"
  # 去掉协议与域名前缀，统一成 owner/repo(.git)
  local s="${url#*github.com/}"
  s="${s#*:}"          # 处理 ssh 形式 git@github.com:owner/repo
  s="${s#/}"           # 去掉前导斜杠
  s="${s%.git}"        # 去掉 .git 后缀
  s="${s%/}"           # 去掉尾斜杠
  echo "$s"
}

REPO_SLUG="$(extract_repo_name "$REPO_URL")"
REPO_NAME="$(basename "$REPO_SLUG")"
if [[ -z "$REPO_NAME" ]]; then
  echo "❌ 无法从 URL 解析仓库名: $REPO_URL"
  exit 2
fi

TS="$(date '+%Y%m%d-%H%M%S')"
# 每个仓库一个独立报告目录，避免多仓库结果互相覆盖
REPORT_BASE="${CHECKER_ROOT}/reports/${REPO_NAME}"
REPORT_DIR="${REPORT_BASE}"
mkdir -p "$REPORT_DIR"

CLONE_DIR="$(mktemp -d -t "csc-${REPO_NAME}-XXXXXX")"

# -------------------- 颜色（不依赖 utils.sh，便于 clone 失败时也能输出） --------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}🔍 远程仓库检查${NC}"
echo -e "  仓库:   ${REPO_URL}"
echo -e "  路径:   ${REPO_SLUG}"
[[ -n "$BRANCH" ]] && echo -e "  分支:   ${BRANCH}"
echo -e "  报告:   ${REPORT_DIR}"
echo ""

# -------------------- 1. Clone --------------------
echo -e "${CYAN}>>> 1/3 克隆仓库${NC}"
CLONE_ARGS=()
if [[ "$DEPTH" != "0" ]]; then
  CLONE_ARGS+=(--depth "$DEPTH")
fi
[[ -n "$BRANCH" ]] && CLONE_ARGS+=(--branch "$BRANCH")
CLONE_ARGS+=(-- "$REPO_URL" "$CLONE_DIR")

if ! git clone "${CLONE_ARGS[@]}" 2>&1 | sed 's/^/    /'; then
  echo -e "${RED}❌ 克隆失败: $REPO_URL${NC}"
  rm -rf "$CLONE_DIR"
  exit 3
fi

# 采集 commit / branch 信息用于报告
CLONE_SHA="$(cd "$CLONE_DIR" && git rev-parse HEAD 2>/dev/null || echo unknown)"
CLONE_BRANCH="$(cd "$CLONE_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "${BRANCH:-default}")"
CLONE_AUTHOR="$(cd "$CLONE_DIR" && git log -1 --format='%an <%ae>' 2>/dev/null || echo unknown)"
CLONE_DATE="$(cd "$CLONE_DIR" && git log -1 --format='%ad' --date=iso 2>/dev/null || echo unknown)"
CLONE_MSG="$(cd "$CLONE_DIR" && git log -1 --format='%s' 2>/dev/null || echo unknown)"

echo -e "    ${GREEN}commit:${NC} ${CLONE_SHA:0:12}  ${GREEN}branch:${NC} ${CLONE_BRANCH}"
echo ""

# -------------------- 2. 运行全量检查 --------------------
echo -e "${CYAN}>>> 2/3 执行全量安全与可靠性检查${NC}"
echo ""

# 通过设置 CI/REPORT_DIR 让 run-checks.sh 生成结构化 Markdown 摘要 (ci-summary.md)
export REPORT_DIR
export CI=true
export CI_COMMIT_SHA="$CLONE_SHA"
export CI_COMMIT_REF_NAME="$CLONE_BRANCH"

RUN_ARGS=(--dir "$CLONE_DIR")
$STRICT && RUN_ARGS+=(--strict)
[[ -n "$ONLY" ]] && RUN_ARGS+=(--only "$ONLY")
[[ -n "$SKIP" ]] && RUN_ARGS+=(--skip "$SKIP")

# 捕获输出同时写入日志
RAW_LOG="${REPORT_DIR}/run-output.log"
bash "${SCRIPT_DIR}/run-checks.sh" "${RUN_ARGS[@]}" 2>&1 | tee "$RAW_LOG"
CHECK_EXIT=${PIPESTATUS[0]}

# 读取结构化摘要（run-checks.sh 在 CI 模式下生成）
SUMMARY_MD="${REPORT_DIR}/ci-summary.md"
SUMMARY_CONTENT=""
[[ -f "$SUMMARY_MD" ]] && SUMMARY_CONTENT="$(cat "$SUMMARY_MD")"

echo ""

# -------------------- 3. 生成独立检查文档 --------------------
echo -e "${CYAN}>>> 3/3 生成检查文档${NC}"

REPORT_FILE="${REPORT_BASE}/${TS}-report.md"
LATEST_FILE="${REPORT_BASE}/latest-report.md"

# 统计检查项（从摘要里抽取；若无摘要则标未知）
gen_report() {
  local verdict_icon verdict_text
  if [[ $CHECK_EXIT -eq 0 ]]; then
    verdict_icon="✅"; verdict_text="通过（未发现阻塞性问题）"
  else
    verdict_icon="❌"; verdict_text="未通过（存在阻塞性问题，详见下文）"
  fi

  {
    echo "# 代码安全与可靠性检查报告"
    echo ""
    echo "> 由 \`code-safety-checker\` 的 \`check-remote.sh\` 自动生成。"
    echo ""
    echo "## 总体结论"
    echo ""
    echo "- ${verdict_icon} **${verdict_text}**"
    echo "- 退出码: \`${CHECK_EXIT}\`"
    echo ""
    echo "## 仓库信息"
    echo ""
    echo "| 项 | 值 |"
    echo "|----|----|"
    echo "| 仓库地址 | ${REPO_URL} |"
    echo "| 仓库路径 | ${REPO_SLUG} |"
    echo "| 分支 | ${CLONE_BRANCH} |"
    echo "| 提交 | \`${CLONE_SHA:0:12}\`（${CLONE_SHA}） |"
    echo "| 最近提交者 | ${CLONE_AUTHOR} |"
    echo "| 提交时间 | ${CLONE_DATE} |"
    echo "| 提交信息 | ${CLONE_MSG} |"
    echo "| 检查时间 | $(date '+%Y-%m-%d %H:%M:%S %z') |"
    echo "| 检查参数 | only=${ONLY:-<全部>} skip=${SKIP:-<无>} strict=${STRICT} depth=${DEPTH} |"
    echo ""

    if [[ -n "$SUMMARY_CONTENT" ]]; then
      echo "## 检查汇总"
      echo ""
      echo "$SUMMARY_CONTENT"
      echo ""
    fi

    echo "## 检查原始输出"
    echo ""
    echo "<details><summary>点击展开 run-checks.sh 完整输出</summary>"
    echo ""
    echo '```'
    # 去除 ANSI 颜色码
    sed -E 's/\x1b\[[0-9;]*m//g' "$RAW_LOG" 2>/dev/null
    echo '```'
    echo ""
    echo "</details>"
    echo ""

    # 列出本次生成的所有报告文件
    echo "## 各检查项产物文件"
    echo ""
    local f
    for f in "$REPORT_DIR"/*; do
      [[ -f "$f" ]] || continue
      local fn
      fn="$(basename "$f")"
      # 跳过本报告自身与 latest
      [[ "$fn" == "$(basename "$REPORT_FILE")" ]] && continue
      [[ "$fn" == "latest-report.md" ]] && continue
      local sz
      sz=$(wc -c < "$f" | tr -d ' ')
      echo "- \`${fn}\`（${sz} 字节）"
    done
    echo ""

    echo "## 说明"
    echo ""
    echo "- 本报告基于克隆时刻的代码快照，不代表仓库后续变更后的状态。"
    echo "- 浅克隆（depth=1）时，历史提交中的敏感信息扫描覆盖范围有限；如需完整历史扫描，请用 \`--depth 0\`。"
    echo "- 详细日志见同目录下 \`checker.log\` 与 \`run-output.log\`。"
    echo ""
  } > "$REPORT_FILE"

  # latest-report.md 软拷贝（独立文件，便于直接引用最新结果）
  cp "$REPORT_FILE" "$LATEST_FILE"
}

gen_report

echo -e "  ${GREEN}📄 检查文档:${NC} ${REPORT_FILE}"
echo -e "  ${GREEN}📄 最新副本:${NC} ${LATEST_FILE}"

# -------------------- 清理 --------------------
if $NO_CLEANUP; then
  echo -e "  ${YELLOW}⚠️ --no-cleanup: 保留克隆目录 ${CLONE_DIR}${NC}"
else
  rm -rf "$CLONE_DIR"
fi

echo ""
if [[ $CHECK_EXIT -eq 0 ]]; then
  echo -e "${GREEN}🎉 检查通过${NC}"
else
  echo -e "${RED}⛔ 检查未通过${NC}"
fi
exit $CHECK_EXIT
