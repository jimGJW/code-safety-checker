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
export REPORT_DIR="${CHECKER_ROOT}/reports"
export LOG_FILE="${REPORT_DIR}/checker.log"
export EXIT_CODE=0
declare -A CHECK_RESULTS
declare -A CHECK_COUNTS=(
  ["total"]=0
  ["passed"]=0
  ["failed"]=0
  ["skipped"]=0
  ["critical"]=0
  ["high"]=0
  ["medium"]=0
  ["low"]=0
)

# -------------------- 日志函数 --------------------

log_info() {
  echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
}

log_debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
  fi
}

log_step() {
  echo -e "\n${CYAN}========================================${NC}" | tee -a "${LOG_FILE}"
  echo -e "${CYAN} 🔍 $*${NC}" | tee -a "${LOG_FILE}"
  echo -e "${CYAN}========================================${NC}" | tee -a "${LOG_FILE}"
}

log_section() {
  echo -e "\n${PURPLE}>>> $*${NC}" | tee -a "${LOG_FILE}"
}

# -------------------- 结果记录函数 --------------------

record_result() {
  local check_name="$1"
  local status="$2"  # passed | failed | skipped
  local severity="${3:-none}"
  local count="${4:-0}"
  local message="${5:-}"

  CHECK_COUNTS["total"]=$((CHECK_COUNTS["total"] + 1))
  CHECK_RESULTS["${check_name}_status"]="$status"
  CHECK_RESULTS["${check_name}_severity"]="$severity"
  CHECK_RESULTS["${check_name}_count"]="$count"
  CHECK_RESULTS["${check_name}_message"]="$message"

  case "$status" in
    passed)
      CHECK_COUNTS["passed"]=$((CHECK_COUNTS["passed"] + 1))
      log_info "✅ ${check_name}: PASSED ${message:+- $message}"
      ;;
    failed)
      CHECK_COUNTS["failed"]=$((CHECK_COUNTS["failed"] + 1))
      [[ -n "$severity" && "$severity" != "none" ]] && CHECK_COUNTS["$severity"]=$((CHECK_COUNTS["$severity"] + count))
      log_error "❌ ${check_name}: FAILED (severity: ${severity}, issues: ${count}) ${message:+- $message}"
      EXIT_CODE=1
      ;;
    skipped)
      CHECK_COUNTS["skipped"]=$((CHECK_COUNTS["skipped"] + 1))
      log_warn "⏭️  ${check_name}: SKIPPED ${message:+- $message}"
      ;;
  esac
}

# -------------------- 工具函数 --------------------

command_exists() {
  command -v "$1" >/dev/null 2>&1
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
    echo "| 总检查项 | ${CHECK_COUNTS['total']} |"
    echo "| ✅ 通过 | ${CHECK_COUNTS['passed']} |"
    echo "| ❌ 失败 | ${CHECK_COUNTS['failed']} |"
    echo "| ⏭️  跳过 | ${CHECK_COUNTS['skipped']} |"
    echo "| 🔥 Critical | ${CHECK_COUNTS['critical']} |"
    echo "| ⚠️  High | ${CHECK_COUNTS['high']} |"
    echo "| 🔔 Medium | ${CHECK_COUNTS['medium']} |"
    echo "| ℹ️  Low | ${CHECK_COUNTS['low']} |"
    echo ""
    echo "## 详细结果"
    echo ""
    for key in "${!CHECK_RESULTS[@]}"; do
      if [[ "$key" == *_status ]]; then
        local name="${key%_status}"
        local s="${CHECK_RESULTS[${name}_status]}"
        local sev="${CHECK_RESULTS[${name}_severity]}"
        local cnt="${CHECK_RESULTS[${name}_count]}"
        local msg="${CHECK_RESULTS[${name}_message]}"
        local icon=""
        case "$s" in
          passed) icon="✅" ;;
          failed) icon="❌" ;;
          skipped) icon="⏭️" ;;
        esac
        echo "- ${icon} **${name}**: ${s} (severity: ${sev}, issues: ${cnt}) ${msg:+- ${msg}}"
      fi
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
