#!/usr/bin/env bash
# ==============================================================================
# 通用工具函数库
# 提供日志输出、颜色显示、结果统计等公共功能
# ==============================================================================

set -o pipefail

# -------------------- 颜色定义 --------------------
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# -------------------- 全局变量 --------------------
export CHECKER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 允许外部覆盖 REPORT_DIR（供 check-remote.sh 为每个被检查仓库生成独立报告目录）
export REPORT_DIR="${REPORT_DIR:-${CHECKER_ROOT}/reports}"
export LOG_FILE="${REPORT_DIR}/checker.log"
export EXIT_CODE=0
# bash 3.2 无关联数组：用独立计数器 + 并行索引数组存结果（macOS 兼容）
CNT_total=0; CNT_passed=0; CNT_failed=0; CNT_skipped=0
CNT_critical=0; CNT_high=0; CNT_medium=0; CNT_low=0
declare -a R_NAME R_STATUS R_SEVERITY R_COUNT R_MESSAGE

# -------------------- 日志函数 --------------------

log_info() {
  echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}" >&2
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}" >&2
}

log_debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}" >&2
  fi
}

log_step() {
  echo -e "\n${CYAN}========================================${NC}" | tee -a "${LOG_FILE}" >&2
  echo -e "${CYAN} 🔍 $*${NC}" | tee -a "${LOG_FILE}" >&2
  echo -e "${CYAN}========================================${NC}" | tee -a "${LOG_FILE}" >&2
}

log_section() {
  echo -e "\n${PURPLE}>>> $*${NC}" | tee -a "${LOG_FILE}" >&2
}

# -------------------- 结果记录函数 --------------------

record_result() {
  local check_name="$1"
  local status="$2"  # passed | failed | skipped
  local severity="${3:-none}"
  local count="${4:-0}"
  local message="${5:-}"

  local idx=${#R_NAME[@]}
  R_NAME[idx]="$check_name"
  R_STATUS[idx]="$status"
  R_SEVERITY[idx]="$severity"
  R_COUNT[idx]="$count"
  R_MESSAGE[idx]="$message"

  CNT_total=$((CNT_total + 1))

  case "$status" in
    passed)
      CNT_passed=$((CNT_passed + 1))
      log_info "✅ ${check_name}: PASSED ${message:+- $message}"
      ;;
    failed)
      CNT_failed=$((CNT_failed + 1))
      case "$severity" in
        critical) CNT_critical=$((CNT_critical + count)) ;;
        high)     CNT_high=$((CNT_high + count)) ;;
        medium)   CNT_medium=$((CNT_medium + count)) ;;
        low)      CNT_low=$((CNT_low + count)) ;;
      esac
      log_error "❌ ${check_name}: FAILED (severity: ${severity}, issues: ${count}) ${message:+- $message}"
      EXIT_CODE=1
      ;;
    skipped)
      CNT_skipped=$((CNT_skipped + 1))
      log_warn "⏭️  ${check_name}: SKIPPED ${message:+- $message}"
      ;;
  esac
}

# -------------------- 工具函数 --------------------

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# -------------------- PCRE grep 兼容封装 --------------------
# macOS toybox/BSD grep 不支持 -P（PCRE），这里统一封装为 grep_p：
#   优先 grep -P（Linux GNU grep）> ggrep -P（brew 装的 GNU grep）> pgrep.py（Python 兜底）
# 用法: grep_p "<pattern>" [--exclude-dir=D]... [--exclude=F]... <dir|file>...
# 输出 "file:line:content"（最多 50 行），无匹配时返回 0 且不输出。

# 探测一次 grep 后端（避免每次 grep_p 调用重复探测，省去每次 ~0.3s）
GREP_P_BIN=""
if echo x | grep -P 'x' >/dev/null 2>&1; then
  GREP_P_BIN="grep"
elif command -v ggrep >/dev/null 2>&1; then
  GREP_P_BIN="ggrep"
fi

grep_p() {
  local pattern="$1"; shift
  local bin="${GREP_P_BIN}"

  if [[ -n "$bin" ]]; then
    local args=() found_dir=0 a
    for a in "$@"; do
      case "$a" in
        --exclude-dir=*|--exclude=*) args+=("$a") ;;
        *) args+=("$a"); [[ -d "$a" ]] && found_dir=1 ;;
      esac
    done
    local rflag=""
    [[ $found_dir -eq 1 ]] && rflag="-r"
    "$bin" -P -H -n -I $rflag "$pattern" "${args[@]}" 2>/dev/null | head -50 || true
  else
    local py
    if command -v python3 >/dev/null 2>&1; then py="python3"; else py="python"; fi
    "$py" "${CHECKER_ROOT}/scripts/pgrep.py" "$pattern" "$@" 2>/dev/null | head -50 || true
  fi
}

# 批量规则扫描：一次 Python 遍历匹配所有规则，避免逐条规则启动解释器的开销。
# 用法: grep_p_batch <rules_file> <dir|file>...   (rules_file 每行: NAME<TAB>PATTERN)
# 输出 "NAME<TAB>file:line:content"（每条规则最多 50 行）
grep_p_batch() {
  local rules_file="$1"; shift
  local py
  if command -v python3 >/dev/null 2>&1; then py="python3"; else py="python"; fi
  "$py" "${CHECKER_ROOT}/scripts/pgrep.py" --batch "$rules_file" "$@" 2>/dev/null || true
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null || true
}

json_get() {
  # 简单的 JSON 字段提取（不依赖 jq 全部情况）
  local file="$1"
  local key="$2"
  if command_exists jq; then
    jq -r "$key // empty" "$file" 2>/dev/null
  else
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/"
  fi
}

detect_project_type() {
  local scan_dir="${1:-.}"
  local types=()

  # 前端检测
  [[ -f "${scan_dir}/package.json" ]] && types+=("frontend-nodejs")
  [[ -f "${scan_dir}/pnpm-lock.yaml" || -f "${scan_dir}/yarn.lock" || -f "${scan_dir}/package-lock.json" ]] && types+=("frontend-pkg")
  [[ -f "${scan_dir}/tsconfig.json" ]] && types+=("frontend-typescript")
  compgen -G "${scan_dir}/*.vue" > /dev/null 2>&1 && types+=("frontend-vue")
  compgen -G "${scan_dir}/*.jsx" > /dev/null 2>&1 && types+=("frontend-react")
  compgen -G "${scan_dir}/*.tsx" > /dev/null 2>&1 && types+=("frontend-react-ts")

  # 后端检测
  [[ -f "${scan_dir}/requirements.txt" || -f "${scan_dir}/pyproject.toml" || -f "${scan_dir}/Pipfile" ]] && types+=("backend-python")
  [[ -f "${scan_dir}/go.mod" ]] && types+=("backend-golang")
  [[ -f "${scan_dir}/pom.xml" ]] && types+=("backend-java")
  [[ -f "${scan_dir}/build.gradle" || -f "${scan_dir}/build.gradle.kts" ]] && types+=("backend-java-gradle")
  [[ -f "${scan_dir}/Gemfile" ]] && types+=("backend-ruby")
  [[ -f "${scan_dir}/Cargo.toml" ]] && types+=("backend-rust")
  [[ -f "${scan_dir}/composer.json" ]] && types+=("backend-php")

  # IaC / 容器检测
  [[ -f "${scan_dir}/Dockerfile" ]] && types+=("docker")
  compgen -G "${scan_dir}/*.tf" > /dev/null 2>&1 && types+=("terraform")
  compgen -G "${scan_dir}/Chart.yaml" > /dev/null 2>&1 && types+=("helm")
  compgen -G "${scan_dir}/*.yaml" -o -G "${scan_dir}/*.yml" 2>/dev/null | xargs grep -l "apiVersion:" 2>/dev/null | head -1 | grep -q . && types+=("k8s")

  echo "${types[@]}"
}

is_in_ci() {
  [[ -n "${GITHUB_ACTIONS:-}" || -n "${GITLAB_CI:-}" || -n "${CI:-}" ]]
}

ci_markdown_summary() {
  # 生成 CI 环境的 Markdown 摘要
  local summary_file="$1"
  {
    echo "# 代码安全与可靠性检查报告"
    echo ""
    echo "**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "**提交版本**: ${CI_COMMIT_SHA:-${GITHUB_SHA:-local}}"
    echo "**分支**: ${CI_COMMIT_REF_NAME:-${GITHUB_REF_NAME:-local}}"
    echo ""
    echo "## 汇总统计"
    echo ""
    echo "| 指标 | 数量 |"
    echo "|------|------|"
    echo "| 总检查项 | ${CNT_total} |"
    echo "| ✅ 通过 | ${CNT_passed} |"
    echo "| ❌ 失败 | ${CNT_failed} |"
    echo "| ⏭️  跳过 | ${CNT_skipped} |"
    echo "| 🔥 Critical | ${CNT_critical} |"
    echo "| ⚠️  High | ${CNT_high} |"
    echo "| 🔔 Medium | ${CNT_medium} |"
    echo "| ℹ️  Low | ${CNT_low} |"
    echo ""
    echo "## 详细结果"
    echo ""
    local i=0
    while [[ $i -lt ${#R_NAME[@]} ]]; do
      local name="${R_NAME[$i]}"
      local s="${R_STATUS[$i]}"
      local sev="${R_SEVERITY[$i]}"
      local cnt="${R_COUNT[$i]}"
      local msg="${R_MESSAGE[$i]}"
      local icon=""
      case "$s" in
        passed) icon="✅" ;;
        failed) icon="❌" ;;
        skipped) icon="⏭️" ;;
      esac
      echo "- ${icon} **${name}**: ${s} (severity: ${sev}, issues: ${cnt}) ${msg:+- ${msg}}"
      i=$((i + 1))
    done
  } > "$summary_file"
}

init_report() {
  ensure_dir "${REPORT_DIR}"
  : > "${LOG_FILE}"
  log_info "代码安全与可靠性检查器 v1.0.0 启动"
  log_info "工作目录: $(pwd)"
  log_info "报告目录: ${REPORT_DIR}"
}
