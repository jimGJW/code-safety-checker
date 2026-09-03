#!/usr/bin/env bash
# ==============================================================================
# 主入口脚本 run-checks.sh
# 串联执行所有检查模块，输出报告，最终返回非零退出码阻塞 MR/PR
# ==============================================================================

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export CHECKER_ROOT

# -------------------- 参数解析 --------------------
SHOW_HELP=false
ONLY=""            # 仅执行指定子检查: secret|dep|frontend|backend|iac|license
SKIP=""            # 跳过指定: secret,dep,frontend,backend,iac,license
SCAN_DIR="."
STRICT_MODE=false
DEBUG=false

usage() {
  cat <<'EOF'
使用方法:
  ./run-checks.sh [选项]

选项:
  -d, --dir <path>       扫描的目标目录 (默认: 当前目录)
  -o, --only <list>      只执行指定检查，逗号分隔: secret,dep,frontend,backend,iac,license
  -s, --skip <list>      跳过指定检查，逗号分隔
      --strict           严格模式：所有 severity >= medium 的问题都阻塞合并
      --debug            输出调试日志
  -h, --help             显示此帮助

示例:
  # 全量检查当前目录
  ./scripts/run-checks.sh

  # 只检查前端 + 敏感信息 + 依赖
  ./scripts/run-checks.sh --only secret,dep,frontend

  # 跳过 IaC 和 License（快路径）
  ./scripts/run-checks.sh --skip iac,license --dir /path/to/repo

  # CI 中启用严格模式
  ./scripts/run-checks.sh --strict

退出码:
  0 = 全部通过
  1 = 存在阻塞性问题 (用于 block Pull/Merge Request)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)       SCAN_DIR="$2"; shift 2 ;;
    -o|--only)      ONLY="$2"; shift 2 ;;
    -s|--skip)      SKIP="$2"; shift 2 ;;
    --strict)       STRICT_MODE=true; shift ;;
    --debug)        DEBUG=true; export DEBUG; shift ;;
    -h|--help)      SHOW_HELP=true; shift ;;
    *)              echo "未知参数: $1"; usage; exit 2 ;;
  esac
done

if $SHOW_HELP; then usage; exit 0; fi

# -------------------- 加载工具库 --------------------
# shellcheck source=scripts/utils.sh
source "${SCRIPT_DIR}/utils.sh"
# shellcheck source=scripts/secret-scan.sh
source "${SCRIPT_DIR}/secret-scan.sh"
# shellcheck source=scripts/dependency-scan.sh
source "${SCRIPT_DIR}/dependency-scan.sh"
# shellcheck source=scripts/frontend-check.sh
source "${SCRIPT_DIR}/frontend-check.sh"
# shellcheck source=scripts/backend-check.sh
source "${SCRIPT_DIR}/backend-check.sh"
# shellcheck source=scripts/iac-container-check.sh
source "${SCRIPT_DIR}/iac-container-check.sh"
# shellcheck source=scripts/license-check.sh
source "${SCRIPT_DIR}/license-check.sh"

# -------------------- 执行控制函数 --------------------
should_run() {
  local name="$1"
  # 白名单优先
  if [[ -n "$ONLY" ]]; then
    [[ ",$ONLY," == *",$name,"* ]] && return 0
    return 1
  fi
  # 黑名单
  if [[ -n "$SKIP" && ",$SKIP," == *",$name,"* ]]; then
    return 1
  fi
  return 0
}

# -------------------- 初始化 --------------------
init_report

log_info "参数: SCAN_DIR=${SCAN_DIR}, ONLY=${ONLY:-<all>}, SKIP=${SKIP:-<none>}, STRICT=${STRICT_MODE}"

# 解析 SCAN_DIR 为绝对路径
SCAN_DIR="$(cd "$SCAN_DIR" && pwd)"
log_info "扫描目录(绝对): ${SCAN_DIR}"
log_info "项目类型检测: $(detect_project_type "${SCAN_DIR}")"

# -------------------- 串联执行 --------------------
START_TS=$(date +%s)

should_run secret   && run_secret_scan "${SCAN_DIR}"      || log_info "跳过: secret scan"
should_run dep      && run_dependency_scan "${SCAN_DIR}"  || log_info "跳过: dependency scan"
should_run frontend && run_frontend_check "${SCAN_DIR}"   || log_info "跳过: frontend check"
should_run backend  && run_backend_check "${SCAN_DIR}"    || log_info "跳过: backend check"
should_run iac      && run_iac_container_check "${SCAN_DIR}" || log_info "跳过: iac/container check"
should_run license  && run_license_check "${SCAN_DIR}"    || log_info "跳过: license check"

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

# -------------------- 汇总 --------------------
log_step "汇总报告"
echo ""
printf "%-30s %-10s %-10s %-10s\n" "检查项" "结果" "严重度" "问题数"
printf "%.0s-" {1..60}; echo ""

_i=0
while [[ $_i -lt ${#R_NAME[@]} ]]; do
  name="${R_NAME[$_i]}"
  s="${R_STATUS[$_i]}"
  sev="${R_SEVERITY[$_i]:-none}"
  cnt="${R_COUNT[$_i]:-0}"
  case "$s" in
    passed)  color=$GREEN  ;;
    failed)  color=$RED    ;;
    skipped) color=$YELLOW ;;
    *)       color=$NC     ;;
  esac
  printf "%b%-30s %-10s %-10s %-10s%b\n" "$color" "$name" "$s" "$sev" "$cnt" "$NC"
  _i=$((_i + 1))
done

echo ""
echo -e "📊 通过: ${GREEN}${CNT_passed}${NC}  |  " \
        "失败: ${RED}${CNT_failed}${NC}  |  " \
        "跳过: ${YELLOW}${CNT_skipped}${NC}  |  " \
        "🔥Critical=${CNT_critical} ⚠️ High=${CNT_high} 🔔Medium=${CNT_medium}"
echo "⏱️  总耗时: ${DURATION} 秒"
echo "📁 报告目录: ${REPORT_DIR}"

# -------------------- CI 摘要 --------------------
if is_in_ci; then
  SUMMARY_FILE="${REPORT_DIR}/ci-summary.md"
  ci_markdown_summary "${SUMMARY_FILE}"
  log_info "已生成 CI Markdown 摘要: ${SUMMARY_FILE}"

  # GitHub Actions: 写 GITHUB_STEP_SUMMARY
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "${SUMMARY_FILE}" >> "${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
    # 上传 artifacts 提示
    echo "" >> "${GITHUB_STEP_SUMMARY}"
    echo "## 详细报告文件" >> "${GITHUB_STEP_SUMMARY}"
    for f in "${REPORT_DIR}"/*; do
      [[ -f "$f" ]] && echo "- \`$(basename "$f")\` (${f})" >> "${GITHUB_STEP_SUMMARY}"
    done
  fi

  # GitLab CI: 写 CI artifacts 会自动收集
  if [[ -n "${GITLAB_CI:-}" ]]; then
    cp "${SUMMARY_FILE}" "${REPORT_DIR}/gl-summary.md" 2>/dev/null || true
  fi
fi

# -------------------- 严格模式 --------------------
if $STRICT_MODE && [[ $EXIT_CODE -eq 0 ]]; then
  # 即便 passed，但 medium 及以上累计超过阈值也阻塞
  if [[ $((CNT_medium + CNT_high + CNT_critical)) -gt 0 ]]; then
    log_warn "--strict 模式开启：存在 medium 以上问题，阻塞 MR/PR"
    EXIT_CODE=1
  fi
fi

echo ""
if [[ ${EXIT_CODE} -eq 0 ]]; then
  log_info "🎉 所有检查均通过，允许合并 (Merge / Pull Request)！"
else
  log_error "⛔ 检查未通过，阻塞合并。请根据上面的报告逐项修复后再提交。"
fi

exit ${EXIT_CODE}
